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
    let profile: ProfileStore
    let voiceFit: VoiceFit
    /// The history entry for the most recent dictation, so later corrections can be attached to it.
    private var lastHistoryID: UUID?
    private var lastActivity = Date()
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
    /// Types into the app while the user speaks (when enabled and a fast model is available).
    private var streamer: StreamTyper?
    /// Distinctive words visible on screen when this take started.
    private var screenTerms: Task<Void, Never>?
    private var screenTermsResult: [String]?
    private var session = 0

    init(prefs: Preferences, models: ModelManager, history: HistoryStore, learning: LearningStore, styles: AppStyleStore, profile: ProfileStore, voiceFit: VoiceFit) {
        self.styles = styles
        self.profile = profile
        self.voiceFit = voiceFit
        self.prefs = prefs
        self.models = models
        self.history = history
        self.learning = learning
        corrections.onCorrection = { [weak learning] heard, written in learning?.learnCorrection(heard: heard, written: written) }
        corrections.onStyleEdit = { [weak styles] edit, key in styles?.record(edit, for: key) }
        corrections.onEdited = { [weak self] text in
            guard let self, let id = self.lastHistoryID else { return }
            self.history.setCorrected(id, text: text)
        }

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
        // Background upkeep while the user is idle: refresh the profile and score models on their voice.
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleUpkeep() }
        }
        Task {
            // Load the companion once the main model is up, so they don't compete for the Neural Engine.
            while !models.activeIsReady { try? await Task.sleep(for: .seconds(1)) }
            models.updateCompanion(enabled: prefs.twoModelAgreement)
        }
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
        screenTerms = nil
        screenTermsResult = nil
        if prefs.screenContext, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let ownVocabulary = Set(vocabulary.map { $0.lowercased() })
            let take = session
            screenTerms = Task {
                let text = await Task.detached(priority: .userInitiated) { ScreenContext.visibleText(pid: pid) }.value
                let terms = TermExtractor.candidates(in: text).filter { !ownVocabulary.contains($0.lowercased()) }
                if self.session == take { self.screenTermsResult = Array(terms.prefix(40)) }
            }
        }
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
        streamer = nil
        if prefs.streamTyping, !overlay.model.editingSelection, focus.hasEditableFocus,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let leading = (!focus.isTerminal && prefs.contextAware && processor.fit("x", before: focus.textBeforeCaret).hasPrefix(" ")) ? " " : ""
            streamer = StreamTyper(pid: pid, leading: leading)
        }
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
        streamer?.cancel()
        streamer = nil
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
                    self.streamer?.cancel()
                    self.streamer = nil
                    self.overlay.flash(.message("Didn't catch that", isError: false), for: 1.6)
                    return
                }
                logger.notice("transcribed in \(result.elapsed, privacy: .public)s: \(result.text.count, privacy: .public) chars")
                var output = result.text
                if let selection = focus.selectedText, !focus.isTerminal, SelectionEditor.isInstruction(result.raw) {
                    self.overlay.model.workingLabel = "Editing"
                    self.overlay.show(.polishing)
                    output = try await SelectionEditor.edit(selection, instruction: result.raw, appName: focus.appName, profile: self.prefs.autoLearn ? self.profile.promptContext : nil)
                    logger.notice("edited selection: \(selection.count, privacy: .public) → \(output.count, privacy: .public) chars")
                }
                self.deliver(output, focus: focus)
                let item = HistoryItem(
                    text: output, rawText: result.raw, modelID: result.modelID,
                    audioSeconds: seconds, processingSeconds: result.elapsed, appName: focus.appName
                )
                self.history.add(item, audio: self.prefs.keepAudio ? samples : nil)
                self.lastHistoryID = item.id
                self.lastActivity = Date()
            } catch {
                // Leave the streamed words in place: they're the best text available.
                self.streamer = nil
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

        // This take's vocabulary: the user's words, what Cadence learned, and names on screen right now.
        let onScreen = await screenTermsForTake()
        let context = TranscriptionContext(
            language: "en",
            vocabulary: vocabulary + onScreen,
            // In a terminal the user's own recent prompts are the useful context, not the screen.
            precedingText: prefs.contextAware ? (focus?.isTerminal == true ? focus?.recentTerminalInput.map { String($0.suffix(300)) } : focus?.textBeforeCaret) : nil,
            profile: prefs.autoLearn ? profile.promptContext : nil
        )
        // Two-model agreement: Parakeet runs alongside (≈0.1 s) and can hear the user's words.
        let companion = (prefs.twoModelAgreement && overrideEngine == nil && !id.hasPrefix("parakeet")) ? models.companion : nil
        async let companionText: String? = { () async -> String? in
            guard let companion else { return nil }
            return try? await companion.transcribe(trimmed, context: context)
        }()
        var raw = try await engine.transcribe(trimmed, context: context)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let other = await companionText?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty, !raw.isEmpty {
            let merged = TranscriptMerger.merge(primary: raw, companion: other, vocabulary: context.vocabulary)
            for d in merged.decisions {
                logger.notice("agreement: took companion's \(d.companion, privacy: .private) over \(d.primary, privacy: .private)")
            }
            raw = merged.text
        }
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
            if let polished = await Polisher.polish(text, appName: focus?.appName, profile: prefs.autoLearn ? profile.promptContext : nil) {
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

    private func idleUpkeep() {
        guard !isRecording, !isProcessing, Date().timeIntervalSince(lastActivity) > 180 else { return }
        if prefs.autoLearn { profile.refreshIfNeeded(history: history, learning: learning) }
        voiceFit.runIfDue(history: history, models: models) { [weak self] id, audio in
            guard let self else { return "" }
            let engine = try await self.models.temporaryEngine(for: id)
            let text = try await engine.transcribe(audio, context: TranscriptionContext(vocabulary: self.vocabulary))
            if id != self.models.activeModelID, engine !== self.models.companion { await engine.unload() }
            return text
        }
    }

    /// Uses the screen read started at key-down if it finished; waits at most 0.25 s for it.
    /// (Polling, not a task group: a group would wait for a slow read to finish before returning.)
    private func screenTermsForTake() async -> [String] {
        guard screenTerms != nil else { return [] }
        let deadline = Date().addingTimeInterval(0.25)
        while screenTermsResult == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return screenTermsResult ?? []
    }

    /// The user's own words first, then what Cadence has learned.
    private var vocabulary: [String] {
        guard prefs.autoLearn else { return prefs.vocabulary }
        var seen = Set(prefs.vocabulary.map { $0.lowercased() })
        var result = prefs.vocabulary
        for term in learning.activeTerms + profile.terms where seen.insert(term.lowercased()).inserted {
            result.append(term)
        }
        return result
    }

    private func deliver(_ text: String, focus: FocusContext) {
        lastText = text
        let streamed = streamer
        streamer = nil
        if focus.hasEditableFocus {
            if let streamed, !streamed.typed.isEmpty, !streamed.stopped {
                streamed.finish(text)
            } else {
                TextInserter.paste(text, restoreClipboard: prefs.restoreClipboard)
            }
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
        // A fast model drives the preview: the active one if it's Parakeet, else the companion.
        let engine: (any TranscriptionEngine)?
        if model.supportsLivePreview, models.activeIsReady { engine = models.activeEngine } else { engine = models.companion }
        guard let engine else { streamer = nil; return }
        let vocabulary = self.vocabulary
        let focus = self.focus
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(self?.streamer == nil ? 900 : 550))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                let audio = self.recorder.snapshot()
                guard audio.count > 12_000 else { continue }
                if let streamer = self.streamer, audio.count <= 16_000 * 90 {
                    // Streaming needs the whole take so far, not just the tail.
                    guard let raw = try? await engine.transcribe(audio, context: TranscriptionContext(vocabulary: vocabulary)),
                          !Task.isCancelled, self.isRecording, !raw.isEmpty else { continue }
                    var text = self.processor.process(raw)
                    if !focus.isTerminal, self.prefs.contextAware { text = self.processor.fit(text, before: focus.textBeforeCaret).trimmingCharacters(in: .whitespaces) }
                    streamer.update(hypothesis: text)
                } else {
                    let tail = Array(audio.suffix(16_000 * 20))
                    let text = try? await engine.transcribe(tail, context: TranscriptionContext(vocabulary: vocabulary))
                    guard !Task.isCancelled, self.isRecording, let text, !text.isEmpty else { continue }
                    self.overlay.model.livePreview = text
                }
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
