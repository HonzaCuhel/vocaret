import AppKit
import Foundation

/// Pauses music while you dictate and resumes it afterwards.
///
/// Only apps whose *playback state* can be read are handled (Spotify, Music):
/// we pause only what is actually playing and resume only what we paused. A
/// blind media-key toggle would risk starting music that was not playing.
/// Uses AppleScript, so macOS asks once per app for Automation permission
/// ("Vocaret wants to control Spotify"). Denied → silently skipped.
public final class MediaPauser: @unchecked Sendable {
    public static let shared = MediaPauser()

    public struct Player: Sendable {
        public let name: String       // AppleScript application name
        public let bundleID: String
    }

    public static let knownPlayers: [Player] = [
        Player(name: "Spotify", bundleID: "com.spotify.client"),
        Player(name: "Music", bundleID: "com.apple.Music"),
    ]

    private let queue = DispatchQueue(label: "com.jancuhel.vocaret.mediapauser", qos: .userInitiated)
    private var pausedByUs: [Player] = []
    private let lock = NSLock()

    public init() {}

    /// Players that are running right now (never launches anything).
    public func runningPlayers() -> [Player] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.knownPlayers.filter { running.contains($0.bundleID) }
    }

    /// Pause every running player that is currently playing. Non-blocking.
    public func pauseIfPlaying(completion: (([Player]) -> Void)? = nil) {
        guard SettingsStore.shared.pauseMediaWhileRecording else { completion?([]); return }
        let players = runningPlayers()
        guard !players.isEmpty else { completion?([]); return }
        queue.async { [self] in
            var paused: [Player] = []
            for player in players where playerState(player) == "playing" {
                if run("tell application \"\(player.name)\" to pause") != nil {
                    paused.append(player)
                }
            }
            lock.lock(); pausedByUs = paused; lock.unlock()
            if !paused.isEmpty { Log.info("Paused \(paused.map(\.name).joined(separator: ", ")) for recording") }
            completion?(paused)
        }
    }

    /// Resume only what we paused. Non-blocking.
    public func resumeIfPaused(completion: (([Player]) -> Void)? = nil) {
        lock.lock(); let players = pausedByUs; pausedByUs = []; lock.unlock()
        guard !players.isEmpty else { completion?([]); return }
        queue.async { [self] in
            var resumed: [Player] = []
            for player in players {
                // Only if the user did not start something else meanwhile.
                guard playerState(player) == "paused" else { continue }
                if run("tell application \"\(player.name)\" to play") != nil { resumed.append(player) }
            }
            if !resumed.isEmpty { Log.info("Resumed \(resumed.map(\.name).joined(separator: ", "))") }
            completion?(resumed)
        }
    }

    /// "playing" | "paused" | "stopped" | nil (not scriptable / permission denied).
    public func playerState(_ player: Player) -> String? {
        run("tell application \"\(player.name)\" to player state as string")?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs AppleScript synchronously on the caller's queue; returns the string
    /// result or nil on error (including a denied Automation permission).
    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743 = not permitted (Automation denied); -600 = app not running.
            Log.warn("AppleScript failed (\(code)): \(error[NSAppleScript.errorMessage] ?? "?")")
            return nil
        }
        return result.stringValue ?? ""
    }
}
