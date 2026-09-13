import Foundation
import CoreGraphics
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "sheeptun", category: "HotkeyManager")

final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let settings: AppSettings
    private let onHotkeyEvent: (Bool) -> Void
    private var isHotkeyDown = false

    init(settings: AppSettings, onHotkeyEvent: @escaping (Bool) -> Void) {
        self.settings = settings
        self.onHotkeyEvent = onHotkeyEvent
    }

    func register() {
        guard AXIsProcessTrusted() else {
            log.warning("Accessibility not granted — showing system prompt")
            promptForAccessibility()
            return
        }
        unregister()   // tear down any previous tap before reinstalling
        installTap()
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

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                if let refcon {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    manager.handleEvent(event)
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else {
            log.error("CGEvent.tapCreate failed — Accessibility permission may not be active yet")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("Event tap installed — listening for keyCode \(self.settings.hotkey.keyCode)")
    }

    private func handleEvent(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(settings.hotkey.keyCode) else { return }

        let optionDown = event.flags.contains(.maskAlternate)
        log.debug("flagsChanged keyCode=\(keyCode) optionDown=\(optionDown) wasDown=\(self.isHotkeyDown)")

        if optionDown && !isHotkeyDown {
            isHotkeyDown = true
            log.info("Hotkey pressed → starting dictation")
            onHotkeyEvent(true)
        } else if !optionDown && isHotkeyDown {
            isHotkeyDown = false
            log.info("Hotkey released → stopping dictation")
            onHotkeyEvent(false)
        }
    }

    deinit {
        unregister()
    }
}
