import SwiftUI
import AppKit
import Combine
import OSLog
import UserNotifications

private let log = Logger(subsystem: "sheeptun", category: "AppDelegate")

@main
struct sheeptunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.dictationSession)
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.permissionsManager)
                .environmentObject(appDelegate)
        } label: {
            MenuBarIconView(session: appDelegate.dictationSession)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    let settings: AppSettings
    let permissionsManager: PermissionsManager
    let dictationSession: DictationSession
    private(set) var hotkeyManager: HotkeyManager?
    private var accessibilityPollTimer: Timer?

    override init() {
        let s = AppSettings()
        let pm = PermissionsManager()
        let session = DictationSession(
            audioRecorder: AudioRecorder(),
            speechEngine: FluidAudioParakeetEngine(),
            textInserter: ClipboardTextInserter(),
            settings: s
        )
        settings = s
        permissionsManager = pm
        dictationSession = session
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log.info("App launched")
        setupNotifications()
        setupHotkey()
        permissionsManager.checkAllPermissions()
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error { log.warning("Notification permission error: \(error)") }
            log.info("Notification permission: \(granted ? "granted" : "denied")")
        }
    }

    func setupHotkey() {
        let session = dictationSession
        if hotkeyManager == nil {
            hotkeyManager = HotkeyManager(settings: settings) { pressed in
                Task { @MainActor in
                    if pressed {
                        await session.startDictation()
                    } else {
                        await session.stopDictation()
                    }
                }
            }
        }
        hotkeyManager?.register()
        permissionsManager.checkAccessibility()
        log.info("Hotkey setup — accessibility: \(self.permissionsManager.accessibilityStatus == .granted ? "granted" : "denied")")

        if permissionsManager.accessibilityStatus != .granted {
            startAccessibilityPolling()
        }
    }

    private func startAccessibilityPolling() {
        guard accessibilityPollTimer == nil else { return }
        log.info("Polling for Accessibility permission…")
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.stopAccessibilityPolling()
                    self.hotkeyManager?.register()
                    self.permissionsManager.checkAccessibility()
                    log.info("Accessibility granted — hotkey auto-registered")
                }
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
    }

    // Show notification banners even while sheeptun is the active process
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
