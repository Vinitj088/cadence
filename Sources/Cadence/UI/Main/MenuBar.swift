import SwiftUI

struct MenuBarIcon: View {
    var dictation: DictationController

    var body: some View {
        Image(systemName: dictation.isRecording ? "waveform.circle.fill" : "waveform")
    }
}

struct MenuBarContent: View {
    @Environment(Preferences.self) private var prefs
    @Environment(ModelManager.self) private var models
    @Environment(DictationController.self) private var dictation

    var body: some View {
        Button(dictation.isRecording ? "Stop Dictation" : "Start Dictation") { dictation.toggle() }
        Button("Paste Last Transcript") { dictation.pasteLast() }
            .disabled(dictation.lastText == nil)

        Divider()

        Menu("Model: \(ModelCatalog.info(prefs.activeModelID).name)") {
            ForEach(ModelCatalog.all) { model in
                Toggle(isOn: Binding(
                    get: { prefs.activeModelID == model.id },
                    set: { on in
                        guard on else { return }
                        prefs.activeModelID = model.id
                        models.activate(model.id)
                    }
                )) {
                    Text(model.name + (ModelStorage.isDownloaded(model.id) ? "" : "  (download)"))
                }
            }
        }

        Text(statusLine)

        Divider()

        Button("Open Cadence…") { NSApp.sendAction(#selector(AppDelegate.showMainWindow), to: nil, from: nil) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Cadence") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch models.status(of: prefs.activeModelID) {
        case .ready: "Hold \(prefs.triggerKey.label) to dictate"
        case .downloading(let p, _): "Downloading model… \(Int(p * 100))%"
        case .loading: "Loading model…"
        case .failed(let m): "Model error: \(m)"
        default: "Model not loaded"
        }
    }
}
