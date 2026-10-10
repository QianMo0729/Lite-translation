import AppKit
import SwiftUI

/// The floating window translations appear in. It takes keyboard focus without activating the
/// app, so the app being read stays in front, and it closes as soon as focus goes elsewhere.
@MainActor
final class TranslationPanelController: NSObject, NSWindowDelegate {
    enum Placement {
        /// Just below the pointer, given in AppKit screen coordinates.
        case nearPointer(NSPoint)
        /// Upper middle of the screen the pointer is on, like Spotlight.
        case upperMiddle
    }

    private let panel: FloatingPanel
    private var topLeft = NSPoint.zero
    private var contentHeight: CGFloat = 46
    var onDismiss: () -> Void = {}

    init(model: PanelModel) {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 46),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        super.init()

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let host = NSHostingView(rootView: PanelView(model: model))
        // The panel is resized from the content's reported height instead; letting the hosting
        // view also constrain the window makes the two fight.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel.contentView = background
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }

        model.onHeightChange = { [weak self] height in
            guard let self, height > 0 else { return }
            contentHeight = height
            layout()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ placement: Placement, focusQuery: Bool) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        switch placement {
        case .nearPointer(let point):
            topLeft = NSPoint(x: point.x + 14, y: point.y - 22)
        case .upperMiddle:
            let visible = screen?.visibleFrame ?? .zero
            topLeft = NSPoint(x: visible.midX - PanelView.width / 2, y: visible.minY + visible.height * 0.72)
        }
        layout()
        panel.makeKeyAndOrderFront(nil)
        // AppKit focuses the first text field on its own; for a selection that would just
        // highlight the whole source text.
        if !focusQuery { panel.makeFirstResponder(nil) }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        hide()
        onDismiss()
    }

    private func layout() {
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - contentHeight)
        let screen = NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - PanelView.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - contentHeight - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: PanelView.width, height: contentHeight)), display: true)
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func windowDidMove(_ notification: Notification) {
        // Follow the user's drag, so later growth keeps the top edge where they left it.
        topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// Delivers a key press to the panel as if it had been typed. Used by the development hook.
    func sendKey(code: Int, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
        ) else { return }
        panel.sendEvent(event)
    }

    /// Saves a picture of the panel's contents. The blurred backdrop doesn't render off screen,
    /// so the contents are drawn over the plain window colour.
    func writeSnapshot(to path: String) {
        guard let view = panel.contentView, let contents = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: contents)
        // Composed at the capture's pixel size, so the picture keeps Retina detail.
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: contents.pixelsWide, pixelsHigh: contents.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        let frame = NSRect(x: 0, y: 0, width: contents.pixelsWide, height: contents.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        frame.fill()
        contents.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private final class FloatingPanel: NSPanel {
    var onCancel: () -> Void = {}

    // Borderless windows refuse key status unless told otherwise.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    // ⌘C, ⌘V and friends normally reach text fields through the Edit menu, which a menu bar
    // app doesn't have.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let action = Self.editActions[key] else { return false }
        return firstResponder?.tryToPerform(action, with: self) ?? false
    }

    private static let editActions: [String: Selector] = [
        "x": #selector(NSText.cut(_:)),
        "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)),
        "a": #selector(NSText.selectAll(_:)),
        "z": Selector(("undo:")),
    ]
}
