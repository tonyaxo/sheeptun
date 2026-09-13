import Foundation
import Combine
import AppKit
import AVFoundation
import ApplicationServices

enum PermissionStatus: Equatable {
    case unknown
    case granted
    case denied
    case restricted
}

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var microphoneStatus: PermissionStatus = .unknown
    @Published private(set) var accessibilityStatus: PermissionStatus = .unknown

    var allGranted: Bool {
        microphoneStatus == .granted &&
        accessibilityStatus == .granted
    }

    func checkAllPermissions() {
        checkMicrophone()
        checkAccessibility()
    }

    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = .granted
        case .denied: microphoneStatus = .denied
        case .restricted: microphoneStatus = .restricted
        case .notDetermined: microphoneStatus = .unknown
        @unknown default: microphoneStatus = .unknown
        }
    }

    func checkAccessibility() {
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = granted ? .granted : .denied
    }

    /// Shows the macOS system prompt: "sheeptun wants to control this computer…"
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.checkAccessibility()
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Privacy-Accessibility")!
        )
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Privacy-Microphone")!
        )
    }
}
