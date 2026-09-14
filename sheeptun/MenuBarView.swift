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
        // Just the state. No transcription preview and no error text: failures are reported
        // by notification, the menu is not a log.
        Label(session.state.displayName, systemImage: session.state.systemImageName)
    }

    @ViewBuilder
    private var hotkeySection: some View {
        Label("Hotkey: \(settings.hotkey.displayString)", systemImage: "keyboard")
        if appDelegate.hotkeyStatus != .active {
            Text("Hotkey listener: \(appDelegate.hotkeyStatus.displayLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        Menu("Permissions") {
            permissionItem("Microphone", status: permissions.microphoneStatus) {
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
                // No "show the prompt" item: the app raises the system prompt itself at launch.
                Button("Open System Settings…") {
                    permissions.openAccessibilitySettings()
                }
                Divider()
                Text("The hotkey activates by itself once access is granted.")
                    .foregroundStyle(.secondary)
            } else if appDelegate.hotkeyStatus == .refused {
                Text("Granted, but the system refused the event tap.")
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    appDelegate.setupHotkey()
                }
            } else {
                Text("Granted ✓")
            }
        }
    }

    @ViewBuilder
    private func permissionItem(
        _ name: String,
        status: PermissionStatus,
        openSettings: @escaping () -> Void
    ) -> some View {
        Menu("\(name): \(status.displayLabel)") {
            // No "request" item: the permission is requested at launch. Once the user has
            // answered, System Settings is the only way back.
            if status != .granted {
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
