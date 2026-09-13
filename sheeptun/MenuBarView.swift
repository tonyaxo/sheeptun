import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var session: DictationSession
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        statusSection
        Divider()
        hotkeySection
        Divider()
        microphoneSection
        Divider()
        permissionsSection
        Divider()
        modelSection
        Divider()
        languageFilterSection
        Divider()
        actionsSection
        Divider()
        Button("Quit sheeptun") {
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Label(session.state.displayName, systemImage: session.state.systemImageName)
        if !session.lastTranscription.isEmpty, session.state == .idle {
            let preview = String(session.lastTranscription.prefix(60))
            let suffix = session.lastTranscription.count > 60 ? "…" : ""
            Text(preview + suffix)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var hotkeySection: some View {
        Label("Hotkey: \(settings.hotkey.displayString)", systemImage: "keyboard")
    }

    @ViewBuilder
    private var microphoneSection: some View {
        Menu("Microphone") {
            Button("System Default") {
                settings.selectedMicrophoneUID = nil
            }
            let devices = AudioRecorder().availableInputDevices()
            if !devices.isEmpty { Divider() }
            ForEach(devices) { device in
                Button(device.name) {
                    settings.selectedMicrophoneUID = device.id
                }
            }
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        Menu("Permissions") {
            permissionItem("Microphone", status: permissions.microphoneStatus) {
                Task { await permissions.requestMicrophone() }
            } openSettings: {
                permissions.openMicrophoneSettings()
            }

            accessibilityPermissionItem

            Divider()
            Button("Refresh Status") {
                permissions.checkAllPermissions()
            }
        }
    }

    @ViewBuilder
    private var accessibilityPermissionItem: some View {
        let status = permissions.accessibilityStatus
        Menu("Accessibility: \(status.displayLabel)") {
            if status != .granted {
                Button("Show System Prompt…") {
                    permissions.requestAccessibility()
                }
                Button("Open System Settings…") {
                    permissions.openAccessibilitySettings()
                }
                Divider()
                Text("Grant access, then click Re-register Hotkey.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Granted ✓")
            }
        }
    }

    @ViewBuilder
    private func permissionItem(
        _ name: String,
        status: PermissionStatus,
        request: (() -> Void)?,
        openSettings: @escaping () -> Void
    ) -> some View {
        Menu("\(name): \(status.displayLabel)") {
            if status == .unknown, let request {
                Button("Request Permission") { request() }
            } else if status == .denied || status == .restricted {
                Button("Open System Settings…") { openSettings() }
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        switch session.modelDownloadState {
        case .downloading:
            Label("Model: Downloading…", systemImage: "arrow.trianglehead.2.clockwise")
            Text("First launch: ~400 MB from HuggingFace")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            Label("Model: Ready", systemImage: "checkmark.circle")
        case .failed(let message):
            Label("Model: Download failed", systemImage: "exclamationmark.triangle")
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Button("Retry Download") {
                Task { await session.retryModelDownload() }
            }
        }
    }

    @ViewBuilder
    private var languageFilterSection: some View {
        let currentName = settings.languageFilterCode
            .flatMap { code in AppSettings.availableLanguageFilters.first { $0.code == code }?.name }
            ?? "None"
        Menu("Language filter: \(currentName)") {
            Button("None (disabled)") {
                settings.languageFilterCode = nil
            }
            Divider()
            ForEach(AppSettings.availableLanguageFilters, id: \.code) { lang in
                Button(lang.name) {
                    settings.languageFilterCode = lang.code
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if session.state == .idle {
            Button("Start Dictation") {
                Task { await session.startDictation() }
            }
            .disabled(!permissions.allGranted)

            if permissions.accessibilityStatus == .granted {
                Button("Re-register Hotkey") {
                    appDelegate.setupHotkey()
                }
            }
        } else if session.state == .recording {
            Button("Stop Dictation") {
                Task { await session.stopDictation() }
            }
            Button("Cancel") {
                Task { await session.cancelDictation() }
            }
        } else {
            Button("Cancel") {
                Task { await session.cancelDictation() }
            }
        }
    }
}

extension PermissionStatus {
    var displayLabel: String {
        switch self {
        case .unknown: return "Not requested"
        case .granted: return "Granted ✓"
        case .denied: return "Denied ✗"
        case .restricted: return "Restricted"
        }
    }
}

struct MenuBarIconView: View {
    @ObservedObject var session: DictationSession

    var body: some View {
        if session.state == .idle {
            Image(nsImage: menuBarAppIcon)
        } else {
            Image(systemName: session.state.systemImageName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
        }
    }

    private var menuBarAppIcon: NSImage {
        let size = NSSize(width: 18, height: 18)
        guard let original = NSImage(named: NSImage.applicationIconName) else {
            return NSImage(size: size)
        }
        let resized = NSImage(size: size)
        resized.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: size),
                      from: .zero,
                      operation: .copy,
                      fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    private var iconColor: Color {
        switch session.state {
        case .idle: return .primary
        case .recording: return .red
        case .processing: return .orange
        case .inserting: return .blue
        case .error: return .yellow
        }
    }
}
