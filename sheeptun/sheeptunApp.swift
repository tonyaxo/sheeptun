import SwiftUI
import AppKit
import Combine
import OSLog

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
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings: AppSettings
    let permissionsManager: PermissionsManager
    let dictationSession: DictationSession
    private(set) var hotkeyManager: HotkeyManager?

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
        setupHotkey()
        permissionsManager.checkAllPermissions()
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
    }
}
