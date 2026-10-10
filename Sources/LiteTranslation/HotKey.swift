import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon hot keys fire without Accessibility permission and
/// swallow the keystroke, so it never reaches the app in front.
@MainActor
final class HotKey {
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?

    private var reference: EventHotKeyRef?
    /// False when another app already owns this shortcut.
    let isRegistered: Bool

    init(keyCode: Int, modifiers: Int, handler: @escaping @MainActor () -> Void) {
        Self.installEventHandlerIfNeeded()
        let id = UInt32(Self.handlers.count + 1)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C54_5258), id: id) // 'LTRX'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
        isRegistered = status == noErr
        Self.handlers[id] = handler
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            // Carbon delivers hot key events on the main run loop.
            MainActor.assumeIsolated { HotKey.handlers[id]?() }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
}
