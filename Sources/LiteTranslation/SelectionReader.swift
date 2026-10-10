import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the text selected in whatever app is in front.
@MainActor
enum SelectionReader {
    static func read() async -> String? {
        if let text = await Task.detached(operation: selectionViaAccessibility).value {
            return text
        }
        // Plenty of apps (browsers, Electron apps, some PDF views) don't expose their
        // selection to Accessibility, so fall back to copying it.
        return await selectionViaCopy()
    }

    private nonisolated static func selectionViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        return (selected as? String)?.trimmedOrNil
    }

    private static func selectionViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let countBefore = pasteboard.changeCount

        // The shortcut that got us here is probably still held down; a ⌘C sent on top of it
        // would arrive as ⌥⌘C.
        await waitForModifierKeysToLift()
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        var copied: String?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(10))
            if pasteboard.changeCount != countBefore {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != countBefore {
            // Put back what the user had on the clipboard.
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            })
        }
        return copied?.trimmedOrNil
    }

    private static func waitForModifierKeysToLift() async {
        let modifiers: CGEventFlags = [.maskAlternate, .maskControl, .maskShift, .maskCommand]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
