import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    // Menu bar only: no Dock icon, and showing the panel never pulls focus from the app in use.
    app.setActivationPolicy(.accessory)
    app.run()
}
