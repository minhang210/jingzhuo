import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var minimizeItem: NSMenuItem!
    var restoreItem: NSMenuItem!
    var barsItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A stable bundle identity prevents multiple copies registering conflicting hotkeys.
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.jingzhuo.CleanDesk")
            .filter { $0.processIdentifier != getpid() }
        if let other = duplicates.first {
            other.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return
        }
        model = AppModel()
        if let path = Bundle.main.url(forResource: "AppIcon-v3", withExtension: "icns"),
           let icon = NSImage(contentsOf: path) { NSApp.applicationIconImage = icon }
        let menu = NSMenu()
        let root = NSMenuItem(); root.submenu = NSMenu(title: "净桌"); menu.addItem(root)
        root.submenu?.addItem(withTitle: "关于净桌", action: #selector(about), keyEquivalent: "")
        root.submenu?.addItem(NSMenuItem.separator())
        root.submenu?.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        root.submenu?.addItem(withTitle: "恢复默认快捷键", action: #selector(resetShortcut), keyEquivalent: "")
        root.submenu?.addItem(withTitle: "隐藏/展开菜单栏和程序坞", action: #selector(toggleBars), keyEquivalent: "")
        root.submenu?.addItem(NSMenuItem.separator())
        root.submenu?.addItem(withTitle: "隐藏净桌", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        root.submenu?.addItem(withTitle: "退出净桌", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "窗口")
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; menu.addItem(windowItem)
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 366), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "净桌"; window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 400, height: 366))
        window.contentMinSize = NSSize(width: 294, height: 352)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: "净桌") { image.isTemplate = true; statusItem.button?.image = image }
        statusItem.button?.toolTip = "净桌 · 收起 / 恢复上次窗口"
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "打开净桌设置…", action: #selector(showSettings), keyEquivalent: "")
        statusMenu.addItem(.separator())
        minimizeItem = statusMenu.addItem(withTitle: "全部最小化", action: #selector(minimizeAll), keyEquivalent: "")
        restoreItem = statusMenu.addItem(withTitle: "恢复上次窗口", action: #selector(restore), keyEquivalent: "")
        barsItem = statusMenu.addItem(withTitle: "隐藏/展开系统栏", action: #selector(toggleBars), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "停止当前操作", action: #selector(cancelOperation), keyEquivalent: "")
        statusMenu.addItem(withTitle: "退出净桌", action: #selector(quit), keyEquivalent: "")
        for item in statusMenu.items where item.action != nil { item.target = self }
        statusMenu.autoenablesItems = false
        statusItem.menu = statusMenu
        model.onStateChanged = { [weak self] in self?.refreshMenu() }
        refreshMenu()
        _ = NSApp.setActivationPolicy(.accessory)
        if !CommandLine.arguments.contains("--background") && !SMLoginItemStarted() { showSettings() }
    }

    private func SMLoginItemStarted() -> Bool {
        NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func refreshMenu() {
        guard model != nil, minimizeItem != nil else { return }
        minimizeItem.title = "\(model.nextAction == .restore ? "恢复上次窗口" : "收起所有窗口")    \(model.shortcut.display)"
        minimizeItem.isEnabled = !model.busy && !model.isRecording
        restoreItem.isEnabled = !model.busy && !model.isRecording && model.recoverableCount > 0
        barsItem.title = "隐藏/展开菜单栏和程序坞    \(model.barsShortcut.display)"
        barsItem.isEnabled = !model.barsBusy && !model.isRecording && !model.barTargets.isEmpty
    }
    @objc func showSettings() {
        guard window != nil else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.updateLoginStatus()
    }
    @objc func minimizeAll() { model.toggleWindows() }
    @objc func restore() { model.restoreWindows() }
    @objc func toggleBars() { model.toggleSystemBars() }
    @objc func cancelOperation() { model.cancelOperation() }
    @objc func resetShortcut() { _ = model.saveShortcut(.standard) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "净桌", .applicationVersion: "0.7.0", .version: "14", .credits: NSAttributedString(string: "独立快捷键控制窗口与系统栏。\n手动打开窗口后，开始新一轮收起。")])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.barsBusy == true {
            model.setMessage("正在修改系统显示设置，请完成后再退出。", error: true)
            return .terminateCancel
        }
        guard model != nil, model.busy || model.recoverableCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "退出净桌？"
        alert.informativeText = model.busy ? "操作会停止。已经最小化的窗口会留在程序坞中。" : "上次收起的窗口会留在程序坞中。退出后，可从程序坞手动恢复窗口。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
