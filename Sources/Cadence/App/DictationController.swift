import AppKit
import AVFoundation
import Observation

/// Runs one dictation from key-down to text-in-the-app.
@Observable
@MainActor
final class DictationController {
    let prefs: Preferences
    let models: ModelManager
    let history: HistoryStore
    let learning: LearningStore
    let styles: AppStyleStore
    let overlay = OverlayController()

    private(set) var isRecording = false
    private(set) var isProcessing = false
    /// The most recent transcript, for "paste last" and the menu bar.
    private(set) var lastText: String?

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let gate = SpeechGate()
    private let muffler = MediaMuffler()
    private let corrections = CorrectionWatcher()
    private let undo = DictationUndo()
    @ObservationIgnored private lazy var undoShortcut = GlobalShortcut(keyCode: 6 /* Z */, flags: [.maskCommand, .maskAlternate]) { [weak self] in
        self?.undoLastDictation()
    }
    private var focus = FocusContext(hasEditableFocus: true)
    private var previewTask: Task<Void, Never>?
    private var session = 0

    init(prefs: Preferences, models: ModelManager, history: HistoryStore, learning: LearningStore, styles: AppStyleStore) {
        self.styles = styles
        self.prefs = prefs
        self.models = models
        self.history = history
        self.learning = learning
        corrections.onCorrection = { [weak learning] heard, written in learning?.learnCorrection(heard: heard, written: written) }
        corrections.onStyleEdit = { [weak styles] edit, key in styles?.record(edit, for: key) }

        recorder.meter = overlay.model.meter
        overlay.onAnchorChanged = { [weak self] anchor in self?.prefs.overlayAnchor = anchor }
        overlay.model.onActivate = { [weak self] in self?.toggle() }
        overlay.model.onStop = { [weak self] in
            self?.hotkey.reset()
            self?.finish()
        }
        overlay.model.onCancel = { [weak self] in
            self?.hotkey.reset()
            self?.cancel()
        }
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start() {
        logger.notice("start: ax=\(Permissions.accessibility, privacy: .public) mic=\(String(describing: Permissions.microphone), privacy: .public) key=\(self.prefs.triggerKey.rawValue, privacy: .public)")
        hotkey.triggerKey = prefs.triggerKey
        hotkey.start()
        undoShortcut.start()
        models.activate(prefs.activeModelID)
        Task { await gate.prepare() }
        if prefs.aiPolish { Polisher.prewarm() }
        overlay.model.anchor = prefs.overlayAnchor
        overlay.setIdleVisible(prefs.showIdlePill)
    }

    func applyOverlaySettings() {
        overlay.setIdleVisible(prefs.showIdlePill)
    }

    func applyTriggerKey() {
        hotkey.triggerKey = prefs.triggerKey
    }

    // MARK: - Hotkey

    private func handle(_ event: HotkeyMonitor.Event) {
        logger.notice("hotkey \(String(describing: event), privacy: .public)")
        switch event {
        case .begin: begin()
        case .lockedHandsFree:
            guard isRecording else { return }
            overlay.show(.listening(handsFree: true))
        case .finish: finish()
        case .cancel: cancel()
        }
    }

    /// Toggle used by the menu bar and the main window's record button.
    func toggle() {
        if isRecording {
            hotkey.reset()
            finish()
        } else {
            begin()
            if isRecording { overlay.show(.listening(handsFree: true)) }
        }
    }

    // MARK: - Lifecycle

    private func begin() {
        guard !isRecording else { return }
        logger.notice("begin: mic=\(String(describing: Permissions.microphone), privacy: .public) ax=\(Permissions.accessibility, privacy: .public) model=\(String(describing: self.models.status(of: self.prefs.activeModelID)), privacy: .public)")
        guard Permissions.microphone == .granted else {
            Permissions.requestMicrophone()
            overlay.flash(.message("Cadence needs microphone access", isError: true), for: 2.2)
            return
        }
        guard Permissions.accessibility else {
            overlay.flash(.message("Allow Accessibility so Cadence can type", isError: true), for: 2.5)
            NSApp.sendAction(#selector(AppDelegate.showOnboarding), to: nil, from: nil)
            return
        }

        focus = FocusContext.capture()
        if prefs.autoLearn {
            // Corrections made since the last take, and words from what the user is writing now.
            corrections.checkNow()
            if let text = focus.isTerminal ? focus.recentTerminalInput : focus.textBeforeCaret { learning.observe(writtenText: text) }
        }
        session += 1
        let device = AudioDevices.resolve(uid: prefs.microphoneUID, preferBuiltIn: prefs.preferBuiltInMic)
        do {
            try recorder.start(device: device)
        } catch {
            logger.error("recorder start failed: \(error.localizedDescription, privacy: .public)")
            overlay.flash(.message(error.localizedDescription, isError: true), for: 2.2)
            return
        }
        isRecording = true
        overlay.model.anchor = prefs.overlayAnchor
        overlay.model.reset()
        // Selected text + speech = an instruction about the selection (shown with a ✎ in the pill).
        overlay.model.editingSelection = focus.selectedText != nil && !focus.isTerminal
        overlay.model.startedAt = Date()
        overlay.show(.listening(handsFree: false))
        Sounds.play(.start, enabled: prefs.playSounds)
        if prefs.muffleMedia { muffler.engage() }
        startLivePreview()

        // Watchdog: if the chosen device delivers nothing, fall back to the system default input.
        let take = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isRecording, self.session == take, self.recorder.sampleCount == 0 else { return }
            logger.error("no audio after 0.5s; restarting on the default input")
            do {
                try self.recorder.start(device: nil)
            } catch {
                logger.error("default input failed too: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        previewTask?.cancel()
        recorder.stop()
        isRecording = false
        muffler.release()
        Sounds.play(.cancel, enabled: prefs.playSounds)
        overlay.hide()
    }

    private func finish() {
        guard isRecording else { return }
        // The final pass must not interleave with a preview pass on the same model.
        let pendingPreview = previewTask
        previewTask?.cancel()
        let samples = recorder.stop()
        let peak = recorder.peakLevel
        isRecording = false
        muffler.release()
        Sounds.play(.stop, enabled: prefs.playSounds)

        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        logger.notice("finish: \(seconds, privacy: .public)s peak=\(peak, privacy: .public)")
        if samples.isEmpty {
            overlay.flash(.message("Couldn't read the microphone", isError: true), for: 2.2)
            return
        }
        guard seconds >= 0.35 else {
            overlay.hide()
            return
        }
        guard peak > 0.05 else {
            overlay.flash(.message("Didn't hear anything — check your mic", isError: true), for: 2)
            return
        }

        let focus = self.focus
        isProcessing = true
        overlay.show(.transcribing)

        Task {
            defer { self.isProcessing = false }
            await pendingPreview?.value
            do {
                let result = try await self.transcribe(samples, focus: focus)
                guard !result.text.isEmpty else {
                    self.overlay.flash(.message("Didn't catch that", isError: false), for: 1.6)
                    return
                }
                logger.notice("transcribed in \(result.elapsed, privacy: .public)s: \(result.text.count, privacy: .public) chars")
                var output = result.text
                if let selection = focus.selectedText, !focus.isTerminal, SelectionEditor.isInstruction(result.raw) {
                    self.overlay.model.workingLabel = "Editing"
                    self.overlay.show(.polishing)
                    output = try await SelectionEditor.edit(selection, instruction: result.raw, appName: focus.appName, profile: nil)
                    logger.notice("edited selection: \(selection.count, privacy: .public) → \(output.count, privacy: .public) chars")
                }
                self.deliver(output, focus: focus)
                self.history.add(
                    HistoryItem(
                        text: output, rawText: result.raw, modelID: result.modelID,
                        audioSeconds: seconds, processingSeconds: result.elapsed, appName: focus.appName
                    ),
                    audio: self.prefs.keepAudio ? samples : nil
                )
            } catch {
                logger.error("transcription failed: \(String(describing: error), privacy: .public)")
                self.overlay.flash(.message((error as? LocalizedError)?.errorDescription ?? "Transcription failed", isError: true), for: 2.5)
            }
        }
    }

    struct Output {
        var text: String
        var raw: String
        var modelID: String
        var elapsed: Double
    }

    /// Full pipeline: VAD trim → engine → number formatting → cleanup → optional polish → fit to caret.
    func transcribe(_ samples: [Float], focus: FocusContext?, modelID: String? = nil, engine overrideEngine: (any TranscriptionEngine)? = nil) async throws -> Output {
        let started = Date()
        let trimmed = await gate.trim(samples)
        guard !trimmed.isEmpty else { return Output(text: "", raw: "", modelID: modelID ?? prefs.activeModelID, elapsed: 0) }

        var id = modelID ?? prefs.activeModelID
        let engine: any TranscriptionEngine
        if let overrideEngine {
            engine = overrideEngine
        } else {
            (id, engine) = try await resolveEngine()
        }

        let context = TranscriptionContext(
            language: "en",
            vocabulary: vocabulary,
            // In a terminal the user's own recent prompts are the useful context, not the screen.
            precedingText: prefs.contextAware ? (focus?.isTerminal == true ? focus?.recentTerminalInput.map { String($0.suffix(300)) } : focus?.textBeforeCaret) : nil
        )
        let raw = try await engine.transcribe(trimmed, context: context)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !Self.isHallucination(raw) else {
            return Output(text: "", raw: raw, modelID: id, elapsed: Date().timeIntervalSince(started))
        }

        var text = raw
        let family = ModelCatalog.info(id).family
        if prefs.smartFormatting, family == .parakeet, id != "parakeet-unified" {
            text = FluidHelpers.normalize(text)
        }
        text = processor.process(text)

        if prefs.aiPolish, focus != nil {
            overlay.show(.polishing)
            if let polished = await Polisher.polish(text, appName: focus?.appName) {
                text = processor.applyVocabulary(processor.applyReplacements(polished))
            }
        }
        if prefs.contextAware, let focus, !focus.isTerminal {
            text = processor.fit(text, before: focus.textBeforeCaret)
        }
        // Per-place style: code in terminals and editors, lists in prompts and email, chat habits.
        if prefs.smartFormatting, let focus {
            text = StyleFormatter.apply(text, rules: styles.rules(for: focus))
        }
        return Output(text: text, raw: raw, modelID: id, elapsed: Date().timeIntervalSince(started))
    }

    private var processor: TextPostProcessor {
        TextPostProcessor(
            removeFillers: prefs.removeFillers,
            smartFormatting: prefs.smartFormatting,
            vocabulary: vocabulary,
            replacements: prefs.replacements + (prefs.autoLearn ? learning.activeReplacements : [])
        )
    }

    /// The chosen model's engine, waiting (with progress in the pill) if it's still downloading or loading.
    private func resolveEngine() async throws -> (String, any TranscriptionEngine) {
        let chosen = prefs.activeModelID
        if let engine = models.activeEngine, models.activeIsReady { return (chosen, engine) }
        if models.activeModelID == nil || (!models.status(of: chosen).isBusy && models.status(of: chosen) != .ready) {
            models.activate(chosen)
        }
        while true {
            if let engine = models.activeEngine, models.activeIsReady { return (chosen, engine) }
            switch models.status(of: chosen) {
            case .downloading(let p, _): overlay.show(.preparing("Downloading model… \(Int(p * 100))%"))
            case .loading: overlay.show(.preparing("Loading model…"))
            case .failed(let message): throw EngineError.unavailable(message)
            default: break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The user's own words first, then what Cadence has learned.
    private var vocabulary: [String] {
        guard prefs.autoLearn else { return prefs.vocabulary }
        let own = Set(prefs.vocabulary.map { $0.lowercased() })
        return prefs.vocabulary + learning.activeTerms.filter { !own.contains($0.lowercased()) }
    }

    private func deliver(_ text: String, focus: FocusContext) {
        lastText = text
        if focus.hasEditableFocus {
            TextInserter.paste(text, restoreClipboard: prefs.restoreClipboard)
            undo.remember(.init(text: text, element: focus.element, isTerminal: focus.isTerminal, pid: NSWorkspace.shared.frontmostApplication?.processIdentifier))
            if prefs.autoLearn, let element = focus.element {
                if focus.isTerminal {
                    corrections.watchScreen(text, in: element, styleKey: focus.styleKey)
                } else {
                    corrections.watch(text, in: element, styleKey: focus.styleKey)
                }
            }
            overlay.flash(.inserted, for: 0.7)
        } else {
            TextInserter.copy(text)
            overlay.flash(.copied, for: 1.8)
        }
    }

    /// Removes the most recent dictation from where it was typed (⌥⌘Z).
    func undoLastDictation() {
        guard !isRecording, undo.last != nil else {
            overlay.flash(.message("Nothing to undo", isError: false), for: 1.2)
            return
        }
        undo.undo()
        overlay.flash(.message("Removed last dictation", isError: false), for: 1.2)
    }

    var canUndo: Bool { undo.last != nil }

    func pasteLast() {
        guard let lastText else { return }
        TextInserter.paste(lastText, restoreClipboard: prefs.restoreClipboard)
    }

    // MARK: - Live preview

    /// For fast models, re-transcribe the tail of the recording about once a second so the
    /// words appear above the pill as the user speaks.
    private func startLivePreview() {
        previewTask?.cancel()
        let model = ModelCatalog.info(prefs.activeModelID)
        guard model.supportsLivePreview, let engine = models.activeEngine, models.activeIsReady else { return }
        let vocabulary = self.vocabulary
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                let audio = self.recorder.snapshot()
                guard audio.count > 12_000 else { continue }
                let tail = Array(audio.suffix(16_000 * 20))
                let text = try? await engine.transcribe(tail, context: TranscriptionContext(vocabulary: vocabulary))
                guard !Task.isCancelled, self.isRecording, let text, !text.isEmpty else { continue }
                self.overlay.model.livePreview = text
            }
        }
    }

    /// Phrases Whisper-family models emit from noise or silence.
    private static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let known: Set<String> = [
            "thank you", "thanks for watching", "thank you for watching", "you", "bye", "subtitles by the amara.org community",
            "please subscribe", "[blank_audio]", "[silence]", "(silence)", "[music]",
        ]
        return known.contains(t)
    }
}
