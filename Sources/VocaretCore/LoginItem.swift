import Foundation
import ServiceManagement

/// "Start at Login" via SMAppService (macOS 13+). Only meaningful when running
/// from a real .app bundle — a bare executable cannot be registered.
public enum LoginItem {
    public static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static var isEnabled: Bool {
        guard isBundled else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Registered, but macOS wants the user to confirm in System Settings.
    public static var needsApproval: Bool {
        isBundled && SMAppService.mainApp.status == .requiresApproval
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Returns the new state (unchanged on failure).
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        guard isBundled else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return enabled
        } catch {
            Log.error("Login item \(enabled ? "registration" : "removal") failed: \(error.localizedDescription)")
            return isEnabled
        }
    }
}
