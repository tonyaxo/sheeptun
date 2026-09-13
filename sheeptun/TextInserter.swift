import Foundation
import AppKit
import CoreGraphics

enum TextInsertionError: LocalizedError {
    case failed(String)
    case accessibilityDenied

    var errorDescription: String? {
        switch self {
        case .failed(let r): return "Text insertion failed: \(r)"
        case .accessibilityDenied: return "Accessibility permission required for text insertion."
        }
    }
}

protocol TextInserting: AnyObject, Sendable {
    func insert(_ text: String) async throws
}

/// Inserts text via clipboard + Cmd+V, preserving original clipboard contents.
final class ClipboardTextInserter: TextInserting, @unchecked Sendable {
    func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw TextInsertionError.accessibilityDenied
        }

        let pasteboard = NSPasteboard.general

        // Snapshot existing clipboard
        let savedTypes = pasteboard.types ?? []
        var savedContents: [(NSPasteboard.PasteboardType, Data)] = []
        for type in savedTypes {
            if let data = pasteboard.data(forType: type) {
                savedContents.append((type, data))
            }
        }

        // Write transcription to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to let the clipboard settle
        try await Task.sleep(for: .milliseconds(30))

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Wait for paste to complete before restoring clipboard
        try await Task.sleep(for: .milliseconds(150))

        // Restore original clipboard
        if !savedContents.isEmpty {
            pasteboard.clearContents()
            for (type, data) in savedContents {
                pasteboard.setData(data, forType: type)
            }
        }
    }
}
