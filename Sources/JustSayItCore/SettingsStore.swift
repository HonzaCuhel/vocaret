import Foundation

/// UserDefaults-backed app configuration. All keys have working defaults so the
/// app runs with zero configuration; the menu and `defaults write` can override.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()

    public static let defaultWhisperModel = "openai_whisper-large-v3-v20240930_626MB"
    public static let fallbackWhisperModel = "openai_whisper-small"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let language = "language"
        static let autoLanguages = "autoLanguages"
        static let whisperModel = "whisperModel"
        static let cleanDictation = "cleanDictation"
        static let cleanMeetings = "cleanMeetings"
        static let keepRecordings = "keepRecordings"
        static let keepDictationHistory = "keepDictationHistory"
        static let pushToTalk = "pushToTalk"
        static let showHUD = "showHUD"
        static let keepModelLoaded = "keepModelLoaded"
        static let dictationKeyCode = "dictationKeyCode"
        static let dictationModifiers = "dictationModifiers"
        static let meetingKeyCode = "meetingKeyCode"
        static let meetingModifiers = "meetingModifiers"
        static let llamaServerPath = "llamaServerPath"
        static let llmModelPath = "llmModelPath"
        static let llmPort = "llmPort"
    }

    // MARK: - Transcription

    /// "auto" (per-utterance detection), "cs", or "en".
    public var language: String {
        get { defaults.string(forKey: Key.language) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    /// When `language == "auto"`, detection is restricted to these codes
    /// (empty = any language Whisper knows). Default cs+en: it prevents
    /// Whisper from mistaking Czech for Slovak/Polish and drives per-utterance
    /// language choice in bilingual meetings.
    public var autoLanguages: [String] {
        get { defaults.stringArray(forKey: Key.autoLanguages) ?? ["cs", "en"] }
        set { defaults.set(newValue, forKey: Key.autoLanguages) }
    }

    public var whisperModel: String {
        get { defaults.string(forKey: Key.whisperModel) ?? Self.defaultWhisperModel }
        set { defaults.set(newValue, forKey: Key.whisperModel) }
    }

    public var keepModelLoaded: Bool {
        get { boolValue(Key.keepModelLoaded, default: true) }
        set { defaults.set(newValue, forKey: Key.keepModelLoaded) }
    }

    // MARK: - Cleanup

    public var cleanDictation: Bool {
        get { boolValue(Key.cleanDictation, default: false) }
        set { defaults.set(newValue, forKey: Key.cleanDictation) }
    }

    public var cleanMeetings: Bool {
        get { boolValue(Key.cleanMeetings, default: true) }
        set { defaults.set(newValue, forKey: Key.cleanMeetings) }
    }

    /// Append every dictation to ~/Library/Application Support/JustSayIt/
    /// dictation-history.md so nothing is ever lost to a failed insertion.
    public var keepDictationHistory: Bool {
        get { boolValue(Key.keepDictationHistory, default: true) }
        set { defaults.set(newValue, forKey: Key.keepDictationHistory) }
    }

    /// Hold-to-talk: holding the dictation hotkey records, releasing it
    /// transcribes and inserts immediately. A quick tap still toggles, so both
    /// styles work without a mode switch.
    public var pushToTalk: Bool {
        get { boolValue(Key.pushToTalk, default: true) }
        set { defaults.set(newValue, forKey: Key.pushToTalk) }
    }

    /// The floating "Recording / Transcribing" pill.
    public var showHUD: Bool {
        get { boolValue(Key.showHUD, default: true) }
        set { defaults.set(newValue, forKey: Key.showHUD) }
    }

    public var keepRecordings: Bool {
        get { boolValue(Key.keepRecordings, default: true) }
        set { defaults.set(newValue, forKey: Key.keepRecordings) }
    }

    // MARK: - Hotkeys (Carbon key codes + Carbon modifier masks)

    /// Defaults: dictation ⌃⌥D, meeting ⌃⌥M.
    /// (Not ⌃⌥Space: on Macs with several keyboard layouts — e.g. U.S. + Czech —
    /// that is macOS's own "Select next source in Input menu" shortcut.)
    /// Carbon masks: cmd 0x100, shift 0x200, option 0x800, control 0x1000.
    public var dictationKeyCode: UInt32 {
        get { uint32Value(Key.dictationKeyCode, default: 2) } // kVK_ANSI_D
        set { defaults.set(Int(newValue), forKey: Key.dictationKeyCode) }
    }

    public var dictationHotkeyLabel: String {
        HotkeyManager.describe(keyCode: dictationKeyCode, modifiers: dictationModifiers)
    }

    public var meetingHotkeyLabel: String {
        HotkeyManager.describe(keyCode: meetingKeyCode, modifiers: meetingModifiers)
    }

    public var dictationModifiers: UInt32 {
        get { uint32Value(Key.dictationModifiers, default: 0x1000 | 0x0800) }
        set { defaults.set(Int(newValue), forKey: Key.dictationModifiers) }
    }

    public var meetingKeyCode: UInt32 {
        get { uint32Value(Key.meetingKeyCode, default: 46) } // kVK_ANSI_M
        set { defaults.set(Int(newValue), forKey: Key.meetingKeyCode) }
    }

    public var meetingModifiers: UInt32 {
        get { uint32Value(Key.meetingModifiers, default: 0x1000 | 0x0800) }
        set { defaults.set(Int(newValue), forKey: Key.meetingModifiers) }
    }

    // MARK: - LLM

    public var llamaServerPath: String? {
        get { defaults.string(forKey: Key.llamaServerPath) }
        set { defaults.set(newValue, forKey: Key.llamaServerPath) }
    }

    public var llmModelPath: String? {
        get { defaults.string(forKey: Key.llmModelPath) }
        set { defaults.set(newValue, forKey: Key.llmModelPath) }
    }

    public var llmPort: Int {
        get {
            let value = defaults.integer(forKey: Key.llmPort)
            return value == 0 ? 8765 : value
        }
        set { defaults.set(newValue, forKey: Key.llmPort) }
    }

    // MARK: - Directories

    public var appSupportDir: URL {
        createdDirectory(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JustSayIt", isDirectory: true)
        )
    }

    public var modelsDir: URL {
        createdDirectory(appSupportDir.appendingPathComponent("Models", isDirectory: true))
    }

    public var meetingsDir: URL {
        createdDirectory(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JustSayIt/Meetings", isDirectory: true)
        )
    }

    public var recordingsDir: URL {
        createdDirectory(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JustSayIt/Recordings", isDirectory: true)
        )
    }

    // MARK: - Helpers

    private func boolValue(_ key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    private func uint32Value(_ key: String, default defaultValue: UInt32) -> UInt32 {
        defaults.object(forKey: key) == nil ? defaultValue : UInt32(truncatingIfNeeded: defaults.integer(forKey: key))
    }

    private func createdDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
