import AppKit
import ServiceManagement

enum LaunchAtLogin {
    /// Login items are path based, so only offer this from a stable install location.
    static var isAvailable: Bool {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" && url.path.hasPrefix("/Applications/")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() throws {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try service.unregister()
        } else {
            try service.register()
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
