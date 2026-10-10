import AppKit
import Carbon.HIToolbox
import LiteTranslationCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = TranslationCoordinator()
    private var statusItem: NSStatusItem?
    private var selectionHotKey: HotKey?
    private var inputHotKey: HotKey?
    private let accessibilityItem = NSMenuItem()
    private let screenRecordingItem = NSMenuItem()
    private let modelItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.warmUp()

        let environment = ProcessInfo.processInfo.environment
        if let query = environment["LT_DEBUG_QUERY"] {
            // A test run takes no shortcuts and shows no menu bar icon, so it never intercepts
            // keystrokes meant for a copy of the app that is in real use.
            print("permissions: accessibility=\(Permissions.accessibility) screenRecording=\(Permissions.screenRecording)")
            print("starts at login: \(LoginItem.isEnabled)")
            coordinator.runDebugQuery(
                query, screenshotPath: environment["LT_DEBUG_SCREENSHOT"],
                documentPath: environment["LT_DEBUG_DOCUMENT"], snapshotPath: environment["LT_DEBUG_SNAPSHOT"]
            )
            return
        }

        selectionHotKey = HotKey(keyCode: kVK_ANSI_D, modifiers: optionKey) { [coordinator] in
            coordinator.translateSelection()
        }
        inputHotKey = HotKey(keyCode: kVK_ANSI_A, modifiers: optionKey) { [coordinator] in
            coordinator.openInput()
        }
        installStatusItem()
        LoginItem.enableOnFirstRun()

        if !Permissions.accessibility { Permissions.promptForAccessibility() }
        if !Permissions.screenRecording { Permissions.promptForScreenRecording() }
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Lite Translation")

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(shortcutItem("翻译选中的文字", key: "d", hotKey: selectionHotKey, action: #selector(translateSelection)))
        menu.addItem(shortcutItem("输入要翻译的内容…", key: "a", hotKey: inputHotKey, action: #selector(openInput)))
        menu.addItem(.separator())
        for item in [accessibilityItem, screenRecordingItem, modelItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "退出 Lite Translation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func shortcutItem(_ title: String, key: String, hotKey: HotKey?, action: Selector) -> NSMenuItem {
        let registered = hotKey?.isRegistered ?? false
        let item = NSMenuItem(title: registered ? title : "\(title)（快捷键被其他应用占用）", action: action, keyEquivalent: registered ? key : "")
        item.keyEquivalentModifierMask = .option
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let accessibility = Permissions.accessibility
        accessibilityItem.title = accessibility ? "辅助功能：已授权" : "辅助功能：未授权，点这里去设置"
        accessibilityItem.action = accessibility ? nil : #selector(openAccessibilitySettings)
        accessibilityItem.isEnabled = !accessibility

        let screenRecording = Permissions.screenRecording
        screenRecordingItem.title = screenRecording ? "屏幕录制：已授权" : "屏幕录制：未授权，点这里去设置"
        screenRecordingItem.action = screenRecording ? nil : #selector(openScreenRecordingSettings)
        screenRecordingItem.isEnabled = !screenRecording

        modelItem.title = OnDeviceTranslator.unavailableMessage.map { "本机模型：\($0)" } ?? "本机模型：可用"
        modelItem.isEnabled = false

        loginItem.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleLoginItem() {
        // A refusal usually means macOS wants the user to approve it in Login Items themselves.
        if !LoginItem.setEnabled(!LoginItem.isEnabled) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // Let the menu finish closing first, so keyboard focus is back in the app being read.
    @objc private func translateSelection() {
        DispatchQueue.main.async { self.coordinator.translateSelection() }
    }

    @objc private func openInput() {
        DispatchQueue.main.async { self.coordinator.openInput() }
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func openScreenRecordingSettings() {
        Permissions.openScreenRecordingSettings()
    }
}
