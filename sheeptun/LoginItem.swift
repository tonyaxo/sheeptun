import Combine
import Foundation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "sheeptun", category: "LoginItem")

/// Launch at login through `SMAppService.mainApp` — the supported route for an app to register
/// itself, with no helper bundle and no entitlement.
///
/// Registration is never done on the app's own initiative: the user turns it on from the menu.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered

    init() {
        refresh()
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }
    /// Kept as a plain Bool so views don't need to import ServiceManagement.
    var isUnavailable: Bool { status == .notFound }

    /// Always read from the system rather than remembering a local copy — the user can change
    /// login items in System Settings behind the app's back.
    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log.info("Registered as a login item")
            } else {
                try SMAppService.mainApp.unregister()
                log.info("Removed from login items")
            }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        log.info("Login item status: \(self.status.displayLabel, privacy: .public)")
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension SMAppService.Status {
    var displayLabel: String {
        switch self {
        case .enabled: return "On"
        case .requiresApproval: return "Needs approval"
        case .notRegistered: return "Off"
        case .notFound: return "Unavailable"
        @unknown default: return "Unknown"
        }
    }
}
