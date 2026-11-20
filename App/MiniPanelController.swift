import AppKit
import SwiftUI

enum MiniGeometry {
    static func size(_ options: MiniPreferences) -> NSSize {
        let diameter = options.safeDiameter
        return options.shape == .ring ? NSSize(width: diameter + 8, height: diameter + 8) : NSSize(width: 126 * diameter / 48 + 8, height: 32 * diameter / 48 + 8)
    }
    static func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, screen.width); frame.size.height = min(frame.height, screen.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        return frame
    }
    static func detailFrame(badge: NSRect, screen: NSRect) -> NSRect {
        let size = NSSize(width: min(340, screen.width), height: min(460, screen.height))
        let right = screen.maxX - badge.maxX, left = badge.minX - screen.minX
        let x = right >= size.width + 8 || right >= left ? badge.maxX + 8 : badge.minX - size.width - 8
        return clamp(NSRect(x: x, y: badge.maxY - size.height, width: size.width, height: size.height), to: screen)
    }
}

private final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MiniInteractionView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onMoved: (() -> Void)?
    var onClick: (() -> Void)?
    var onExpand: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    private var tracking: NSTrackingArea?
    private var downPoint = NSPoint.zero
    private var downOrigin = NSPoint.zero
    private var dragging = false
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        downPoint = NSEvent.mouseLocation; downOrigin = window?.frame.origin ?? .zero; dragging = false
        onDrag?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        let dx = point.x - downPoint.x, dy = point.y - downPoint.y
        guard dragging || hypot(dx, dy) >= 3 else { return }
        dragging = true; window?.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }
    override func mouseUp(with event: NSEvent) {
        onDrag?(false)
        if dragging { onMoved?() }
        else if event.clickCount >= 2 { onExpand?() }
        else { onClick?() }
        dragging = false
    }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event, self) }
}

private final class MiniHoverView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor final class MiniPanelController: NSObject {
    let badge: NSPanel
    let detail: NSPanel
    private let store: BoardStore
    private let persistPosition: Bool
    private var positioned = false
    private var enabled = false
    private var dragging = false
    private var menuDepth = 0
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var pointerTimer: Timer?
    private var menuObservers: [NSObjectProtocol] = []
    // Injected by interaction tests; production always uses the real global pointer.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var onExpand: (() -> Void)?
    var isDetailVisible: Bool { detail.isVisible }

    init(store: BoardStore, persistPosition: Bool = true) {
        self.store = store; self.persistPosition = persistPosition
        badge = MiniPanel(contentRect: NSRect(origin: .zero, size: MiniGeometry.size(store.preferences.miniOptions)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        detail = MiniPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 460), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        for window in [badge, detail] {
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
            window.becomesKeyOnlyIfNeeded = true; window.isMovable = false
            window.isExcludedFromWindowsMenu = true
        }
        badge.title = "AgentBoard 迷你圆环"; detail.title = "AgentBoard 悬停详情"
        let interaction = MiniInteractionView(frame: NSRect(origin: .zero, size: badge.frame.size))
        let hosting = NSHostingView(rootView: MiniBadgeView().environmentObject(store))
        hosting.frame = interaction.bounds; hosting.autoresizingMask = [.width, .height]; interaction.addSubview(hosting)
        interaction.onHover = { [weak self] in self?.badgeHoverChanged($0) }
        interaction.onDrag = { [weak self] in self?.draggingChanged($0) }
        interaction.onMoved = { [weak self] in self?.finishMoving() }
        interaction.onClick = { [weak self] in self?.showDetail() }
        interaction.onExpand = { [weak self] in self?.expand() }
        interaction.onContextMenu = { [weak self] event, view in self?.showMenu(event: event, view: view) }
        badge.contentView = interaction
        let hover = MiniHoverView(rootView: MiniDetailView(onExpand: { [weak self] in self?.expand() }, onClose: { [weak self] in self?.dismissDetail() }).environmentObject(store))
        hover.onHover = { [weak self] in self?.detailHoverChanged($0) }; detail.contentView = hover
        for (name, begins) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.menuTrackingChanged(begins) }
            })
        }
    }
    deinit { menuObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    func apply(preferences: BoardPreferences, visible: Bool, anchor: NSRect) {
        enabled = visible
        for window in [badge, detail] {
            window.level = preferences.pinned ? .floating : .normal
            window.collectionBehavior = preferences.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        }
        if !positioned {
            if persistPosition, let saved = UserDefaults.standard.string(forKey: "AgentBoard.MiniFrame") {
                let frame = NSRectFromString(saved)
                if frame.width > 0 && frame.height > 0 { badge.setFrameOrigin(frame.origin); positioned = true }
            }
            if !positioned { badge.setFrameOrigin(NSPoint(x: anchor.maxX - badge.frame.width, y: anchor.maxY - badge.frame.height)); positioned = true }
        }
        let size = MiniGeometry.size(preferences.miniOptions)
        if badge.frame.size != size {
            let old = badge.frame
            badge.setFrame(NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        if visible { ensureVisible(); badge.orderFrontRegardless(); if detail.isVisible { positionDetail() } }
        else { hide() }
    }
    func hide() { enabled = false; dismissDetail(); badge.orderOut(nil) }
    func ensureVisible() {
        guard let screen = screenForBadge() else { return }
        badge.setFrame(MiniGeometry.clamp(badge.frame, to: screen.visibleFrame), display: true)
        if detail.isVisible { positionDetail() }
    }
    func savePosition() {
        guard persistPosition, positioned else { return }
        UserDefaults.standard.set(NSStringFromRect(badge.frame), forKey: "AgentBoard.MiniFrame")
    }
    private func finishMoving() { ensureVisible(); savePosition() }
    private func screenForBadge() -> NSScreen? {
        NSScreen.screens.max { a, b in
            let i = a.visibleFrame.intersection(badge.frame), j = b.visibleFrame.intersection(badge.frame)
            return max(0, i.width) * max(0, i.height) < max(0, j.width) * max(0, j.height)
        } ?? NSScreen.main
    }
    private func positionDetail() {
        guard let screen = screenForBadge() else { return }
        detail.setFrame(MiniGeometry.detailFrame(badge: badge.frame, screen: screen.visibleFrame), display: true)
    }
    func badgeHoverChanged(_ inside: Bool) {
        if inside {
            closeTask?.cancel(); closeTask = nil
            guard enabled, !dragging, menuDepth == 0 else { return }
            openTask?.cancel()
            openTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, self.badge.frame.contains(self.pointerLocation()) else { return }
                self.showDetail()
            }
        } else { openTask?.cancel(); openTask = nil; scheduleClose() }
    }
    func detailHoverChanged(_ inside: Bool) {
        if inside { closeTask?.cancel(); closeTask = nil }
        else { scheduleClose() }
    }
    func draggingChanged(_ value: Bool) {
        dragging = value
        if value { dismissDetail() }
    }
    func showDetail() {
        guard enabled, !dragging, menuDepth == 0 else { return }
        openTask?.cancel(); openTask = nil; closeTask?.cancel(); closeTask = nil
        positionDetail(); detail.orderFrontRegardless()
        store.miniDetailOpen = true
        if pointerTimer == nil {
            pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPointer() }
            }
        }
    }
    func dismissDetail() {
        store.miniDetailOpen = false
        openTask?.cancel(); openTask = nil; closeTask?.cancel(); closeTask = nil
        pointerTimer?.invalidate(); pointerTimer = nil; detail.orderOut(nil)
    }
    private func containsPointer() -> Bool {
        let point = pointerLocation()
        return badge.frame.contains(point) || detail.isVisible && detail.frame.contains(point)
    }
    private func checkPointer() {
        guard detail.isVisible, menuDepth == 0 else { return }
        if containsPointer() { closeTask?.cancel(); closeTask = nil }
        else { scheduleClose() }
    }
    private func scheduleClose() {
        guard detail.isVisible, menuDepth == 0, closeTask == nil else { return }
        closeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self else { return }
            self.closeTask = nil
            if self.menuDepth == 0 && !self.containsPointer() { self.dismissDetail() }
        }
    }
    private func menuTrackingChanged(_ begins: Bool) {
        menuDepth = max(0, menuDepth + (begins ? 1 : -1))
        if begins { openTask?.cancel(); openTask = nil; closeTask?.cancel(); closeTask = nil }
        else { checkPointer() }
    }
    private func expand() { dismissDetail(); onExpand?() }
    private func showMenu(event: NSEvent, view: NSView) {
        openTask?.cancel(); openTask = nil
        let menu = NSMenu()
        for metric in MiniMetric.allCases {
            let item = menu.addItem(withTitle: metric.title, action: #selector(selectMetric(_:)), keyEquivalent: "")
            item.representedObject = metric.rawValue; item.state = store.preferences.miniOptions.metric == metric ? .on : .off; item.target = self
        }
        menu.addItem(.separator())
        for shape in MiniShape.allCases {
            let item = menu.addItem(withTitle: shape.title, action: #selector(selectShape(_:)), keyEquivalent: "")
            item.representedObject = shape.rawValue; item.state = store.preferences.miniOptions.shape == shape ? .on : .off; item.target = self
        }
        if !store.selectedAccounts.isEmpty {
            let accountMenu = NSMenu()
            let selected = store.preferences.miniOptions.accountID ?? store.selectedAccounts.first?.id
            for account in store.selectedAccounts {
                let item = accountMenu.addItem(withTitle: store.preferences.name(for: account), action: #selector(selectAccount(_:)), keyEquivalent: "")
                item.representedObject = account.id; item.state = account.id == selected ? .on : .off; item.target = self
            }
            let item = menu.addItem(withTitle: "余额账号", action: nil, keyEquivalent: ""); item.submenu = accountMenu
        }
        menu.addItem(.separator())
        let expandItem = menu.addItem(withTitle: "展开完整浮窗", action: #selector(expandFromMenu), keyEquivalent: ""); expandItem.target = self
        let settings = menu.addItem(withTitle: "迷你模式设置…", action: #selector(settingsFromMenu), keyEquivalent: ""); settings.target = self
        let hide = menu.addItem(withTitle: "隐藏浮窗", action: #selector(hideFromMenu), keyEquivalent: ""); hide.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    @objc private func selectMetric(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let metric = MiniMetric(rawValue: raw) else { return }
        var mini = store.preferences.miniOptions; mini.metric = metric; store.preferences.miniOptions = mini; store.save()
    }
    @objc private func selectShape(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let shape = MiniShape(rawValue: raw) else { return }
        var mini = store.preferences.miniOptions; mini.shape = shape; store.preferences.miniOptions = mini; store.save()
    }
    @objc private func selectAccount(_ item: NSMenuItem) {
        var mini = store.preferences.miniOptions; mini.accountID = item.representedObject as? String; store.preferences.miniOptions = mini; store.save()
    }
    @objc private func expandFromMenu() { expand() }
    @objc private func settingsFromMenu() { dismissDetail(); NotificationCenter.default.post(name: .boardShowSettings, object: nil) }
    @objc private func hideFromMenu() { NotificationCenter.default.post(name: .boardHidePanel, object: nil) }
}
