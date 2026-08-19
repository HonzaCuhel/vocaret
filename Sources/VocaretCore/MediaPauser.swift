import AppKit
import Foundation

/// Pauses music while you dictate and resumes it afterwards.
///
/// Only apps whose *playback state* can be read are handled (Spotify, Music):
/// we pause only what is actually playing and resume only what we paused. A
/// blind media-key toggle would risk starting music that was not playing.
/// Uses `osascript` (a separate process — no in-process AppleScript threading
/// caveats), so macOS asks once per app for Automation permission. Denied →
/// silently skipped.
///
/// All work runs on one serial queue, so `resumeIfPaused()` always executes
/// AFTER a preceding `pauseIfPlaying()` even when the dictation lasted 300 ms.
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
    /// Only touched on `queue`.
    private var pausedByUs: [Player] = []

    public init() {}

    /// Players that are running right now (never launches anything).
    public func runningPlayers() -> [Player] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.knownPlayers.filter { running.contains($0.bundleID) }
    }

    /// Ask for the Automation permission at a calm moment (app launch) instead
    /// of mid-recording, where the system prompt would steal focus.
    public func primePermissions() {
        guard SettingsStore.shared.pauseMediaWhileRecording else { return }
        let players = runningPlayers()
        if !players.isEmpty {
            queue.async { [self] in for p in players { _ = playerState(p) } }
        }
        // A player launched later gets its prompt at launch time, not at the
        // next recording.
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
            ) { [weak self] note in
                guard let self, SettingsStore.shared.pauseMediaWhileRecording,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let player = Self.knownPlayers.first(where: { $0.bundleID == app.bundleIdentifier }) else { return }
                // The app needs a moment before it answers Apple Events.
                self.queue.asyncAfter(deadline: .now() + 4) {
                    if self.automationStatus(player) == OSStatus(errAEEventWouldRequireUserConsent) { _ = self.playerState(player) }
                }
            }
        }
    }
    private var launchObserver: NSObjectProtocol?

    /// noErr = granted, errAEEventWouldRequireUserConsent = macOS has not asked
    /// yet, errAEEventNotPermitted = denied.
    func automationStatus(_ player: Player) -> OSStatus {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID).aeDesc else { return -1 }
        var address = target.pointee
        return AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, false)
    }

    /// Players the user has not been asked about yet: skipped mid-recording
    /// (the modal permission prompt would steal focus from the recording and
    /// from the app the text is meant for) and asked about afterwards.
    private var primeAfterRecording: [Player] = []

    /// Pause every running player that is currently playing. Non-blocking.
    public func pauseIfPlaying(completion: (([Player]) -> Void)? = nil) {
        guard SettingsStore.shared.pauseMediaWhileRecording else { completion?([]); return }
        let players = runningPlayers()
        guard !players.isEmpty else { completion?([]); return }
        queue.async { [self] in
            var paused: [Player] = []
            var ready: [Player] = []
            for player in players {
                if automationStatus(player) == OSStatus(errAEEventWouldRequireUserConsent) {
                    Log.info("Automation for \(player.name) not decided yet — not pausing it mid-recording; will ask afterwards")
                    primeAfterRecording.append(player)
                } else {
                    ready.append(player)
                }
            }
            for player in ready where playerState(player) == "playing" {
                if run("tell application \"\(player.name)\" to pause") != nil { paused.append(player) }
            }
            pausedByUs = paused
            if !paused.isEmpty { Log.info("Paused \(paused.map(\.name).joined(separator: ", ")) for recording") }
            completion?(paused)
        }
    }

    /// Resume only what we paused. Non-blocking; ordered after any pending pause.
    public func resumeIfPaused(completion: (([Player]) -> Void)? = nil) {
        queue.async { [self] in
            let resumed = resumeNow()
            completion?(resumed)
            // Recording is over; give the transcript a few seconds to land in
            // the target app, then ask (the one-time prompt steals focus).
            let pending = primeAfterRecording
            primeAfterRecording.removeAll()
            if !pending.isEmpty {
                queue.asyncAfter(deadline: .now() + 6) { [self] in for player in pending { _ = playerState(player) } }
            }
        }
    }

    /// Synchronous variant for app termination (the process is about to exit,
    /// so an async resume would never run). Bounded by osascript's own speed.
    public func resumeIfPausedNow() {
        queue.sync { _ = resumeNow() }
    }

    /// Must run on `queue`.
    private func resumeNow() -> [Player] {
        let players = pausedByUs
        pausedByUs = []
        guard !players.isEmpty else { return [] }
        let stillRunning = Set(runningPlayers().map(\.bundleID))
        var resumed: [Player] = []
        for player in players {
            // Do not launch a player the user quit meanwhile, and do not
            // override something they started playing themselves.
            guard stillRunning.contains(player.bundleID), playerState(player) == "paused" else { continue }
            if run("tell application \"\(player.name)\" to play") != nil { resumed.append(player) }
        }
        if !resumed.isEmpty { Log.info("Resumed \(resumed.map(\.name).joined(separator: ", "))") }
        return resumed
    }

    /// "playing" | "paused" | "stopped" | nil (not scriptable / permission denied).
    public func playerState(_ player: Player) -> String? {
        run("tell application \"\(player.name)\" to player state as string")?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs AppleScript in an `osascript` child (attributed to Vocaret for TCC).
    /// Returns stdout, or nil on any error (including a denied permission).
    private func run(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Log.warn("osascript failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return stdout
    }
}
