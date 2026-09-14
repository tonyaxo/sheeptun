import AppKit
import Combine
import OSLog
import SwiftUI
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
    /// One shared recorder for the whole app. Never build one in a SwiftUI body — its deinit
    /// has to hop to the MainActor and doing that mid-render crashes the view update.
    let audioRecorder: AudioRecorder

    @Published private(set) var hotkeyStatus: HotkeyTapStatus = .inactive

    private(set) var hotkeyManager: HotkeyManager?
    private var accessibilityPollTimer: Timer?
    private var tapRetryCount = 0

    override init() {
        let s = AppSettings()
        let pm = PermissionsManager()
        let recorder = AudioRecorder()
        let session = DictationSession(
            audioRecorder: recorder,
            speechEngine: FluidAudioParakeetEngine(),
            textInserter: ClipboardTextInserter(),
            settings: s
        )
        settings = s
        permissionsManager = pm
        audioRecorder = recorder
        dictationSession = session
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log.info("App launched")
        permissionsManager.checkAllPermissions()

        Task { @MainActor in
            // Ask for notifications first: the model-download banners are posted right after
            // and would be dropped while authorization is still undetermined.
            await requestNotificationAuthorization()
            // Then the microphone, so first launch prompts without the user opening the menu.
            await requestMicrophoneIfNeeded()
            setupHotkey()
            // Before the model: the audio cold start is what the first keypress would pay for.
            audioRecorder.prewarm()
            await dictationSession.start()
        }
    }

    private func requestNotificationAuthorization() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            let granted = try await center.requestAuthorization(options: [.alert])
            log.info("Notification permission: \(granted ? "granted" : "denied")")
        } catch {
            log.warning("Notification permission error: \(error)")
        }
    }

    private func requestMicrophoneIfNeeded() async {
        permissionsManager.checkMicrophone()
        guard permissionsManager.microphoneStatus == .unknown else {
            log.info("Microphone already decided: \(String(describing: self.permissionsManager.microphoneStatus))")
            return
        }
        log.info("Requesting microphone permission at launch")
        await permissionsManager.requestMicrophone()
    }

    func setupHotkey() {
        let session = dictationSession
        if hotkeyManager == nil {
            let manager = HotkeyManager(settings: settings) { pressed in
                Task { @MainActor in
                    if pressed {
                        await session.startDictation()
                    } else {
                        await session.stopDictation()
                    }
                }
            }
            manager.onStatusChange = { [weak self] status in
                Task { @MainActor [weak self] in self?.hotkeyStatus = status }
            }
            hotkeyManager = manager
        }
        tapRetryCount = 0
        let status = hotkeyManager?.register() ?? .inactive
        hotkeyStatus = status
        permissionsManager.checkAccessibility()
        log.info("Hotkey setup — tap: \(status.displayLabel, privacy: .public)")

        switch status {
        case .needsAccessibility:
            startAccessibilityPolling()
        case .refused:
            // TCC sometimes lags behind the toggle by a moment; retry briefly before giving up.
            scheduleTapRetry()
        case .active, .inactive:
            break
        }
    }

    private func startAccessibilityPolling() {
        guard accessibilityPollTimer == nil else { return }
        log.info("Polling for Accessibility permission…")
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard AXIsProcessTrusted() else { return }
                self.stopAccessibilityPolling()
                self.permissionsManager.checkAccessibility()
                let status = self.hotkeyManager?.register() ?? .inactive
                self.hotkeyStatus = status
                log.info("Accessibility granted — tap: \(status.displayLabel, privacy: .public)")
                if status == .refused { self.scheduleTapRetry() }
            }
        }
        // The menu opening puts the main run loop into event-tracking mode, which would
        // otherwise stall the timer while the user is reading the Permissions submenu.
        if let accessibilityPollTimer {
            RunLoop.main.add(accessibilityPollTimer, forMode: .common)
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
    }

    private func scheduleTapRetry() {
        guard tapRetryCount < 5 else {
            log.error("Event tap still refused after \(self.tapRetryCount) retries")
            return
        }
        tapRetryCount += 1
        let delay = Double(tapRetryCount)
        log.info("Retrying event tap in \(delay)s (attempt \(self.tapRetryCount))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.hotkeyStatus != .active else { return }
            let status = self.hotkeyManager?.register() ?? .inactive
            self.hotkeyStatus = status
            if status == .refused { self.scheduleTapRetry() }
        }
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
