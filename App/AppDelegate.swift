import AppKit
import SwiftUI
import Combine

final class FloatingBoard: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = BoardStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private(set) var panel: FloatingBoard!
    private(set) var miniController: MiniPanelController!
    private var settings: NSWindow?
    private var observation: AnyCancellable?
    private var compact = false
    private var expandedSize = NSSize(width: 370, height: 670)
    private var snapshotMode: Bool { CommandLine.arguments.contains("--snapshot") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); return }
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); return }
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        miniController = MiniPanelController(store: store, persistPosition: !snapshotMode)
        miniController.onExpand = { [weak self] in
            guard let self else { return }
            self.store.preferences.compact = false; self.store.save()
        }
        buildStatusItem()
        store.onPreferencesChanged = { [weak self] in self?.applyPreferences() }
        observation = store.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.updateStatus() } }
        NotificationCenter.default.addObserver(self, selector: #selector(showPanel), name: .boardShowPanel, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hidePanel), name: .boardHidePanel, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showSettings), name: .boardShowSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showAccounts), name: .boardShowAccounts, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showAbout), name: .boardShowAbout, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showStatistics), name: .boardShowStatistics, object: nil)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.ensureVisible() } }
        applyPreferences()
        if CommandLine.arguments.contains("--snapshot") { SnapshotRenderer.run(delegate: self); return }
        store.start()
        if store.preferences.onboardingCompleted != true { store.showOnboarding = true; showSettings() }
    }
    private func buildPanel() {
        if !snapshotMode {
            let width = UserDefaults.standard.double(forKey: "AgentBoard.ExpandedWidth"), height = UserDefaults.standard.double(forKey: "AgentBoard.ExpandedHeight")
            if width >= 280 && height >= 160 { expandedSize = NSSize(width: width, height: height) }
        }
        panel = FloatingBoard(contentRect: NSRect(x: 0, y: 0, width: 370, height: 670), styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = BoardIdentity.title; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true; panel.minSize = NSSize(width: 280, height: 160); panel.delegate = self
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.contentView = NSHostingView(rootView: DashboardView().environmentObject(store))
        if !snapshotMode { panel.setFrameAutosaveName("AgentBoard.Float") }
        if (snapshotMode || !panel.setFrameUsingName("AgentBoard.Float")), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 395, y: screen.visibleFrame.maxY - 710))
        }
        // Earlier versions stored the collapsed bar in the full dashboard's frame.
        if panel.frame.height < 200 {
            let old = panel.frame
            panel.setFrame(NSRect(x: old.minX, y: old.maxY - expandedSize.height, width: expandedSize.width, height: expandedSize.height), display: false)
        }
        ensureVisible()
    }
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover = NSPopover(); popover.behavior = .transient; popover.contentSize = NSSize(width: 370, height: 620)
        popover.contentViewController = NSHostingController(rootView: DashboardView(popover: true).environmentObject(store))
        updateStatus()
    }
    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "AgentBoard")
        button.imagePosition = .imageLeading
        switch store.preferences.menuMetric {
        case "tokens": button.title = " " + BoardFormat.tokens(store.snapshot.usage.total)
        case "balance":
            if let first = store.selectedAccounts.first, let balance = store.snapshot.balances.first(where: { $0.id == first.id }), let amount = balance.remaining { button.title = " " + BoardFormat.money(amount, unit: balance.unit) }
            else { button.title = " —" }
        case "icon": button.title = ""
        default: button.title = " \(store.snapshot.running)" + (store.snapshot.waiting > 0 ? " · \(store.snapshot.waiting)!" : "")
        }
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = "AgentBoard · \(store.snapshot.running) 个执行中 · \(store.snapshot.waiting) 个等待确认"
    }
    func applyPreferences() {
        guard panel != nil else { return }
        panel.level = store.preferences.pinned ? .floating : .normal
        panel.collectionBehavior = store.preferences.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        if compact != store.preferences.compact {
            if store.preferences.compact { expandedSize = panel.frame.size; saveExpandedSize() }
            compact = store.preferences.compact
        }
        miniController?.apply(preferences: store.preferences, visible: compact && store.preferences.floatVisible, anchor: panel.frame)
        if store.preferences.floatVisible && !compact { ensureVisible(); panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        updateStatus()
    }
    @objc func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "显示浮窗", action: #selector(showPanel), keyEquivalent: "")
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "关于 AgentBoard…", action: #selector(showAbout), keyEquivalent: "")
            menu.addItem(.separator()); menu.addItem(withTitle: "退出 AgentBoard", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }; statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    @objc func showPanel() { store.preferences.floatVisible = true; store.save() }
    @objc func hidePanel() { store.preferences.floatVisible = false; store.save() }
    @objc func showSettings() { openSettings(tab: 0) }
    @objc func showAccounts() { openSettings(tab: 1) }
    @objc func showStatistics() { openSettings(tab: 4); NotificationCenter.default.post(name: .boardSelectStatisticsTab, object: nil) }
    @objc func showAbout() {
        miniController?.dismissDetail(); popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: BoardIdentity.author)])
    }
    private func openSettings(tab: Int) {
        popover?.performClose(nil)
        miniController?.dismissDetail()
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 670), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "AgentBoard 设置"; window.minSize = NSSize(width: 680, height: 600); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BoardSettingsView(selectedTab: tab).environmentObject(store)); window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
        if tab == 1 { NotificationCenter.default.post(name: .boardSelectAccountsTab, object: nil) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func application(_ application: NSApplication, open urls: [URL]) { showPanel() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationWillTerminate(_ notification: Notification) { if !snapshotMode { panel?.saveFrame(usingName: "AgentBoard.Float"); miniController?.savePosition() } }
    func windowDidMove(_ notification: Notification) { if !snapshotMode { panel?.saveFrame(usingName: "AgentBoard.Float") } }
    func windowDidEndLiveResize(_ notification: Notification) { if !snapshotMode { panel?.saveFrame(usingName: "AgentBoard.Float"); if !compact { expandedSize = panel.frame.size; saveExpandedSize() } } }
    private func saveExpandedSize() {
        guard !snapshotMode else { return }
        UserDefaults.standard.set(expandedSize.width, forKey: "AgentBoard.ExpandedWidth")
        UserDefaults.standard.set(expandedSize.height, forKey: "AgentBoard.ExpandedHeight")
    }
    private func ensureVisible() {
        miniController?.ensureVisible()
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersection(panel.frame).width > 100 && $0.visibleFrame.intersection(panel.frame).height > 80 }), let screen = NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24, y: screen.visibleFrame.maxY - min(panel.frame.height, screen.visibleFrame.height) - 24))
    }
}
