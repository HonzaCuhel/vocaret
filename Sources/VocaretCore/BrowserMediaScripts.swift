import Foundation

/// Browser-owned markers disappear on navigation. Only YouTube videos paused
/// by this recording can resume; manual seeking or source changes invalidate it.
enum BrowserMediaScripts {
    static let browsers: [MediaPauser.Player] = [
        .init(name: "Google Chrome", bundleID: "com.google.Chrome"),
        .init(name: "Safari", bundleID: "com.apple.Safari"),
        .init(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        .init(name: "Brave Browser", bundleID: "com.brave.Browser")
    ]

    static func javascript(pausing: Bool, token: String) -> String {
        let operation = pausing ? """
        if (!v.paused && !v.ended) {
            v.pause();
            v.__vocaretPause = {token: token, src: v.currentSrc, time: v.currentTime};
            changed = true;
        }
        """ : """
        const saved = v.__vocaretPause;
        if (saved && saved.token === token) {
            delete v.__vocaretPause;
            if (v.paused && !v.ended && v.currentSrc === saved.src && Math.abs(v.currentTime - saved.time) < 1) {
                v.play().catch(() => {});
                changed = true;
            }
        }
        """
        // token is generated internally, never page/user text.
        return """
        (() => {
            if (!(location.hostname === 'youtube.com' || location.hostname.endsWith('.youtube.com'))) return 'skipped';
            const token = '\(token)';
            let changed = false;
            for (const v of document.querySelectorAll('video')) { \(operation) }
            return changed ? 'changed' : 'skipped';
        })()
        """
    }

    static func script(browser: MediaPauser.Player, pausing: Bool, token: String) -> String {
        let js = javascript(pausing: pausing, token: token)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let command = browser.bundleID == "com.apple.Safari"
            ? "do JavaScript \"\(js)\" in t"
            : "execute t javascript \"\(js)\""
        return """
        tell application "\(browser.name)"
            set changed to false
            set failed to false
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set pageURL to URL of t
                        if pageURL contains "youtube.com/" then
                            set resultText to \(command)
                            if resultText is "changed" then set changed to true
                        end if
                    on error
                        set failed to true
                    end try
                end repeat
            end repeat
            if changed then return "changed"
            if failed then return "unavailable"
            return "skipped"
        end tell
        """
    }
}
