import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "sheeptun", category: "HotkeyManager")

enum HotkeyTapStatus: Equatable {
    case inactive
    case active
    case needsAccessibility
    /// Accessibility is granted but the system still refused the event tap.
    case refused

    var displayLabel: String {
        switch self {
        case .inactive: return "Not active"
        case .active: return "Active ✓"
        case .needsAccessibility: return "Waiting for Accessibility"
        case .refused: return "Refused by system"
        }
    }
}

final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let settings: AppSettings
    private let onHotkeyEvent: (Bool) -> Void
    private var isHotkeyDown = false

    private(set) var status: HotkeyTapStatus = .inactive
    /// Called whenever `status` changes, so the menu can show why the hotkey isn't working.
    var onStatusChange: ((HotkeyTapStatus) -> Void)?

    init(settings: AppSettings, onHotkeyEvent: @escaping (Bool) -> Void) {
        self.settings = settings
        self.onHotkeyEvent = onHotkeyEvent
    }

    @discardableResult
    func register() -> HotkeyTapStatus {
        guard AXIsProcessTrusted() else {
            log.warning("Accessibility not granted — showing system prompt")
            promptForAccessibility()
            setStatus(.needsAccessibility)
            return status
        }
        unregister()   // tear down any previous tap before reinstalling
        installTap()
        return status
    }

    func unregister() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func setStatus(_ new: HotkeyTapStatus) {
        guard status != new else { return }
        status = new
        onStatusChange?(new)
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func installTap() {
        // flagsChanged carries the modifier presses; tapDisabled* arrive on the same callback
        // and must be handled or the tap stays dead after the system times it out.
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                if let refcon {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    switch type {
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        manager.handleTapDisabled(type)
                    default:
                        manager.handleEvent(event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else {
            log.error("CGEvent.tapCreate refused while AXIsProcessTrusted() == true")
            setStatus(.refused)
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setStatus(.active)
        log.info("Event tap installed — listening for keyCode \(self.settings.hotkey.keyCode)")
    }

    /// The system disables a tap that takes too long to respond, or on user input during
    /// a secure-input session. Re-enabling the existing tap is enough to recover.
    private func handleTapDisabled(_ type: CGEventType) {
        log.warning("Event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — re-enabling")
        isHotkeyDown = false
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(settings.hotkey.keyCode) else { return }

        // maskAlternate is set while *either* Option key is down, so a left-Option press
        // would mask the right key's release. The device-dependent bit is per physical key.
        let isDown: Bool
        if let deviceMask = Self.deviceDependentMask(forKeyCode: settings.hotkey.keyCode) {
            isDown = (event.flags.rawValue & deviceMask) != 0
        } else {
            isDown = event.flags.contains(.maskAlternate)
        }

        log.debug("flagsChanged keyCode=\(keyCode) down=\(isDown) wasDown=\(self.isHotkeyDown)")

        if isDown && !isHotkeyDown {
            isHotkeyDown = true
            log.info("Hotkey pressed → starting dictation")
            onHotkeyEvent(true)
        } else if !isDown && isHotkeyDown {
            isHotkeyDown = false
            log.info("Hotkey released → stopping dictation")
            onHotkeyEvent(false)
        }
    }

    /// NX_DEVICE*KEYMASK bits, which identify the individual physical modifier key.
    private static func deviceDependentMask(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 58: return 0x0000_0020   // left Option
        case 61: return 0x0000_0040   // right Option
        case 59: return 0x0000_0001   // left Control
        case 62: return 0x0000_2000   // right Control
        case 56: return 0x0000_0002   // left Shift
        case 60: return 0x0000_0004   // right Shift
        case 55: return 0x0000_0008   // left Command
        case 54: return 0x0000_0010   // right Command
        default: return nil
        }
    }

    deinit {
        unregister()
    }
}
