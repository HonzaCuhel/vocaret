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
    private var browserToken: String?
    private var pausedBrowsers: [Player] = []
    private var pauseActive = false

    public init() {}

    /// Players that are running right now (never launches anything).
    private func runningMediaApps() -> [Player] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return (Self.knownPlayers + BrowserMediaScripts.browsers).filter { running.contains($0.bundleID) }
    }

    public func runningPlayers() -> [Player] {
        runningMediaApps().filter { player in Self.knownPlayers.contains { $0.bundleID == player.bundleID } }
    }

    /// Ask for the Automation permission at a calm moment (app launch) instead
    /// of mid-recording, where the system prompt would steal focus.
    public func primePermissions() {
        guard SettingsStore.shared.pauseMediaWhileRecording else { return }
        let players = runningMediaApps()
        if !players.isEmpty {
            queue.async { [self] in for p in players { _ = probePlayer(p) } }
        }
        // A player launched later gets its prompt at launch time, not at the
        // next recording.
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
            ) { [weak self] note in
                guard let self, SettingsStore.shared.pauseMediaWhileRecording,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let player = (Self.knownPlayers + BrowserMediaScripts.browsers).first(where: { $0.bundleID == app.bundleIdentifier }) else { return }
                // The app needs a moment before it answers Apple Events.
                self.queue.asyncAfter(deadline: .now() + 4) {
                    if self.automationStatus(player) == OSStatus(errAEEventWouldRequireUserConsent) { _ = self.probePlayer(player) }
                }
            }
        }
    }
    private var launchObserver: NSObjectProtocol?

    /// noErr = granted, errAEEventWouldRequireUserConsent = macOS has not asked
    /// yet, errAEEventNotPermitted = denied.
    func automationStatus(_ player: Player) -> OSStatus {
        // Keep the descriptor alive: `aeDesc` is an interior pointer, and the
        // temporary would be released before the AEDesc is read.
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        guard let target = descriptor.aeDesc else { return -1 }
        var address = target.pointee
        let status = AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, false)
        withExtendedLifetime(descriptor) {}
        return status
    }

    /// Self-test hook: send a bare command ("play", "pause") to a player.
    @discardableResult
    func send(_ verb: String, to player: Player) -> Bool {
        run("tell application \"\(player.name)\" to \(verb)") != nil
    }

    /// Players the user has not been asked about yet: skipped mid-recording
    /// (the modal permission prompt would steal focus from the recording and
    /// from the app the text is meant for) and asked about afterwards.
    private var primeAfterRecording: [Player] = []

    /// Pause every running player that is currently playing. Non-blocking.
    public func pauseIfPlaying(completion: (([Player]) -> Void)? = nil) {
        guard SettingsStore.shared.pauseMediaWhileRecording else { completion?([]); return }
        Task { @MainActor in CompanionModel.shared.mediaStatus = nil }
        let players = runningMediaApps()
        guard !players.isEmpty else { completion?([]); return }
        queue.async { [self] in
            guard !pauseActive else { completion?([]); return }
            pauseActive = true
            let token = UUID().uuidString
            browserToken = token
            var paused: [Player] = []
            var ready: [Player] = []
            for player in players {
                if automationStatus(player) == OSStatus(errAEEventWouldRequireUserConsent) {
                    Log.info("Automation for \(player.name) not decided yet — not pausing it mid-recording; will ask afterwards")
                    primeAfterRecording.append(player)
                    Task { @MainActor in CompanionModel.shared.mediaStatus = L("Media pause needs Automation permission.") }
                } else {
                    ready.append(player)
                }
            }
            // One osascript per player: the state check and the pause execute
            // together, so a played-then-paused player can never be recorded
            // wrongly, and the round-trip cost is paid once, not twice.
            for player in ready {
                if BrowserMediaScripts.browsers.contains(where: { $0.bundleID == player.bundleID }) {
                    let result = run(BrowserMediaScripts.script(browser: player, pausing: true, token: token))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if result == "changed" { pausedBrowsers.append(player) }
                    else if result == "unavailable" || result == nil {
                        Task { @MainActor in CompanionModel.shared.mediaStatus = L("YouTube: enable Allow JavaScript from Apple Events in your browser.") }
                        Log.warn("YouTube pause unavailable in \(player.name): enable Automation and Allow JavaScript from Apple Events")
                    }
                    continue
                }
                switch run(Self.pauseIfPlayingScript(player.name))?.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "paused":
                    paused.append(player)
                case "not-playing", "":
                    break
                default:
                    // Persisted (warning) on purpose: if the pause landed but
                    // the reply was lost, music stays paused with no auto-resume.
                    Log.warn("Pause check for \(player.name) failed — it will NOT be auto-resumed")
                }
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
                queue.asyncAfter(deadline: .now() + 6) { [self] in for player in pending { _ = probePlayer(player) } }
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
        pauseActive = false
        if let token = browserToken {
            let running = Set(runningMediaApps().map(\.bundleID))
            for browser in pausedBrowsers where running.contains(browser.bundleID) {
                _ = run(BrowserMediaScripts.script(browser: browser, pausing: false, token: token))
            }
        }
        pausedBrowsers = []
        browserToken = nil
        let players = pausedByUs
        pausedByUs = []
        guard !players.isEmpty else { return [] }
        let stillRunning = Set(runningMediaApps().map(\.bundleID))
        var resumed: [Player] = []
        for player in players {
            // Do not launch a player the user quit meanwhile, and do not
            // override something they started playing themselves.
            guard stillRunning.contains(player.bundleID) else {
                Log.warn("Not resuming \(player.name): no longer running"); continue
            }
            // Single script: skip only a player that left playback entirely
            // (stopped — `play` could start something unrelated). A stale
            // "playing" right after our own pause is fine: play is a no-op on
            // a genuinely playing player.
            switch run(Self.resumeUnlessStoppedScript(player.name))?.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "playing":
                resumed.append(player)
            case "stopped":
                Log.warn("Not resuming \(player.name): playback is stopped")
            default:
                Log.warn("Resume command for \(player.name) failed")
            }
        }
        if !resumed.isEmpty { Log.info("Resumed \(resumed.map(\.name).joined(separator: ", "))") }
        return resumed
    }

    static func pauseIfPlayingScript(_ name: String) -> String {
        """
        tell application "\(name)"
            if player state is playing then
                pause
                return "paused"
            end if
            return "not-playing"
        end tell
        """
    }

    static func resumeUnlessStoppedScript(_ name: String) -> String {
        """
        tell application "\(name)"
            if player state is stopped then return "stopped"
            play
            return "playing"
        end tell
        """
    }

    private func probePlayer(_ player: Player) -> String? {
        if BrowserMediaScripts.browsers.contains(where: { $0.bundleID == player.bundleID }) {
            return run("tell application \"\(player.name)\" to count windows")
        }
        return playerState(player)
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
        let started = Date()
        do { try process.run() } catch { return nil }
        // A hung osascript (e.g. a consent dialog the user never answers)
        // would otherwise block the serial queue forever — and with it every
        // future pause AND resume.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            Log.warn("osascript timed out after 10 s — killed")
            return nil
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 2 { Log.warn("osascript took \(String(format: "%.1f", elapsed)) s") }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Log.warn("osascript failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return stdout
    }
}
