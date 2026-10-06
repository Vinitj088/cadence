import Foundation
import Observation

/// The physical key that starts dictation. Right-hand modifiers are the default because
/// they're rarely used in shortcuts, so holding one never collides with typing.
enum TriggerKey: String, CaseIterable, Identifiable, Codable {
    case rightOption, leftOption, eitherOption, rightCommand, rightControl, fn, rightShift

    var id: String { rawValue }

    var keyCodes: Set<UInt16> {
        switch self {
        case .rightOption: [61]
        case .leftOption: [58]
        case .eitherOption: [58, 61]
        case .rightCommand: [54]
        case .rightControl: [62]
        case .fn: [63]
        case .rightShift: [60]
        }
    }

    var label: String {
        switch self {
        case .rightOption: "Right ⌥ Option"
        case .leftOption: "Left ⌥ Option"
        case .eitherOption: "Either ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        case .fn: "🌐 Fn / Globe"
        case .rightShift: "Right ⇧ Shift"
        }
    }

    var glyph: String {
        switch self {
        case .rightOption, .leftOption, .eitherOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        case .fn: "fn"
        case .rightShift: "⇧"
        }
    }
}

/// Where the overlay pill rests. The user can drag it anywhere; it snaps to the nearest of these.
enum OverlayAnchor: String, CaseIterable, Identifiable, Codable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }

    /// -1 left, 0 centre, 1 right.
    var column: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .top, .bottom: 0
        case .topRight, .right, .bottomRight: 1
        }
    }

    /// -1 bottom, 0 middle, 1 top.
    var row: Int {
        switch self {
        case .topLeft, .top, .topRight: 1
        case .left, .right: 0
        case .bottomLeft, .bottom, .bottomRight: -1
        }
    }

    var isTop: Bool { row == 1 }
}

/// One user-defined correction: anything the engine hears as `spoken` becomes `written`.
struct Replacement: Codable, Identifiable, Hashable {
    var id = UUID()
    var spoken: String
    var written: String
}

/// All user settings, persisted to UserDefaults on every change.
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") } }
    var triggerKey: TriggerKey { didSet { save(triggerKey, "triggerKey") } }
    var activeModelID: String { didSet { defaults.set(activeModelID, forKey: "activeModelID") } }
    var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    var preferBuiltInMic: Bool { didSet { defaults.set(preferBuiltInMic, forKey: "preferBuiltInMic") } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Keep a thin resting pill on screen between dictations, Dynamic Island style.
    var showIdlePill: Bool { didSet { defaults.set(showIdlePill, forKey: "showIdlePill") } }
    var overlayAnchor: OverlayAnchor { didSet { save(overlayAnchor, "overlayAnchor") } }
    var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    var smartFormatting: Bool { didSet { defaults.set(smartFormatting, forKey: "smartFormatting") } }
    var contextAware: Bool { didSet { defaults.set(contextAware, forKey: "contextAware") } }
    var aiPolish: Bool { didSet { defaults.set(aiPolish, forKey: "aiPolish") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: "keepAudio") } }
    var vocabulary: [String] { didSet { save(vocabulary, "vocabulary") } }
    var replacements: [Replacement] { didSet { save(replacements, "replacements") } }

    private init() {
        defaults.register(defaults: [
            "preferBuiltInMic": true,
            "playSounds": true,
            "showIdlePill": true,
            "removeFillers": true,
            "smartFormatting": true,
            "contextAware": true,
            "aiPolish": false,
            "restoreClipboard": true,
            "keepAudio": true,
        ])
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        triggerKey = Self.load("triggerKey", defaults) ?? .rightOption
        activeModelID = defaults.string(forKey: "activeModelID") ?? ModelCatalog.defaultModelID
        microphoneUID = defaults.string(forKey: "microphoneUID")
        preferBuiltInMic = defaults.bool(forKey: "preferBuiltInMic")
        playSounds = defaults.bool(forKey: "playSounds")
        showIdlePill = defaults.bool(forKey: "showIdlePill")
        overlayAnchor = Self.load("overlayAnchor", defaults) ?? .bottom
        removeFillers = defaults.bool(forKey: "removeFillers")
        smartFormatting = defaults.bool(forKey: "smartFormatting")
        contextAware = defaults.bool(forKey: "contextAware")
        aiPolish = defaults.bool(forKey: "aiPolish")
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        keepAudio = defaults.bool(forKey: "keepAudio")
        vocabulary = Self.load("vocabulary", defaults) ?? []
        replacements = Self.load("replacements", defaults) ?? []
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
