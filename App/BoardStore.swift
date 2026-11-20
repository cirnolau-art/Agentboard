import Foundation
import SwiftUI
import WidgetKit

actor MonitorEngine {
    private let readers = AgentReaders()
    private var snapshot = BoardSnapshot.empty
    private var lastUsage = Date.distantPast
    private var ccIssue: String?
    private var lastStatistics = Date.distantPast
    func poll(_ preferences: BoardPreferences, force: Bool = false) -> BoardSnapshot {
        var next = snapshot
        next.updatedAt = Date(); next.tasks = []; next.health = []; next.issues = []
        if force || Date().timeIntervalSince(lastUsage) >= preferences.usageInterval || snapshot.usageDay != BoardFormat.day() {
            do {
                let providers = try CCReader.providers(path: preferences.ccPath)
                let (usage, accounts) = try CCReader.usage(path: preferences.ccPath, accounts: providers.map(\.account))
                next.accounts = accounts; next.usage = usage; next.usageDay = BoardFormat.day(); next.usageUpdatedAt = Date(); lastUsage = Date(); ccIssue = nil
            } catch { ccIssue = "CC Switch：" + error.localizedDescription }
        }
        if let ccIssue { next.issues.append(ccIssue) }
        if force || Date().timeIntervalSince(lastStatistics) >= 60 || snapshot.usageDay != BoardFormat.day() {
            do { next.statistics = try UsageAnalytics.read(path: preferences.ccPath); lastStatistics = Date() }
            catch { next.issues.append("统计暂不可用：" + error.localizedDescription) }
        }
        for raw in preferences.enabledAgents {
            guard let kind = AgentKind(rawValue: raw) else { continue }
            let result = readers.read(kind, path: preferences.path(for: kind))
            next.tasks += result.tasks; next.health.append(result.health)
        }
        // Inbox events can enrich built-in observations, retaining their explicit event state.
        let inbox = SharedStorage.localDirectory.appendingPathComponent("events").path
        if FileManager.default.fileExists(atPath: inbox) {
            let events = readers.read(.custom, path: inbox).tasks
            for event in events where preferences.enabledAgents.contains(event.agent.rawValue) || event.agent == .custom && preferences.enabledAgents.contains("custom") {
                if let i = next.tasks.firstIndex(where: { $0.id == event.id }) { if event.updatedAt >= next.tasks[i].updatedAt { next.tasks[i] = event } }
                else { next.tasks.append(event) }
            }
        }
        next.tasks.sort { $0.state.rank == $1.state.rank ? $0.updatedAt > $1.updatedAt : $0.state.rank < $1.state.rank }
        for index in next.tasks.indices { next.tasks[index].requestUsage = next.statistics?.sessionUsage[next.tasks[index].id] }
        snapshot = next
        return next
    }
}

@MainActor final class BoardStore: ObservableObject {
    @Published var snapshot: BoardSnapshot
    @Published var preferences: BoardPreferences
    @Published var refreshing = false
    @Published var balanceRefreshing = false
    @Published var notice: String?
    @Published var miniDisplayMetric: MiniMetric?
    @Published var notificationStatus = "未开启"
    @Published var detectedAgents: [AgentKind] = []
    @Published var showOnboarding = false
    var onPreferencesChanged: (() -> Void)?
    private let engine = MonitorEngine()
    private let balances = BalanceService()
    private var timer: Timer?
    private var lastPoll = Date.distantPast
    private var lastBalance = Date.distantPast
    private var lastWidgetWrite = Date.distantPast
    private var polling = false
    private var lastWidgetSignature = ""
    private var sleeping = false
    private var balanceRefreshPending = false
    private let notifications: BoardNotifications
    private var rotationIndex = 0
    private var lastRotation = Date()
    var miniDetailOpen = false
    private let testing: Bool
    init() {
        testing = CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--diagnose")
        notifications = BoardNotifications(testing: testing)
        preferences = SharedStorage.read(BoardPreferences.self, name: "preferences.json", directory: SharedStorage.localDirectory) ?? BoardPreferences()
        snapshot = SharedStorage.read(BoardSnapshot.self, name: "snapshot.json") ?? .empty
        notifications.onError = { [weak self] in self?.notice = $0 }
    }
    var accounts: [APIAccount] {
        snapshot.accounts + preferences.manualAccounts.map { APIAccount(id: "manual:" + $0.id, providerID: $0.id, appType: "自定义", name: $0.name, balanceKind: $0.staticAmount == nil ? "custom" : "manual", current: false) }
    }
    var selectedAccounts: [APIAccount] { accounts.filter { preferences.selectedAccounts.contains($0.id) } }
    var visibleTasks: [AgentTask] {
        let tasks = snapshot.tasks.filter { preferences.enabledAgents.contains($0.agent.rawValue) }
        return preferences.showRecentCompleted ? tasks : tasks.filter { ![.completed, .interrupted, .idle].contains($0.state) }
    }
    func start() {
        detectAgents()
        Task { await updateNotificationStatus() }
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleeping = true } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleeping = false; self?.refresh(force: true); self?.refreshBalances() } }
    }
    private func tick() {
        guard !sleeping else { return }
        if Date().timeIntervalSince(lastPoll) >= preferences.taskInterval { refresh() }
        if Date().timeIntervalSince(lastBalance) >= preferences.balanceInterval { refreshBalances() }
        rotateMiniIfNeeded()
    }
    func refresh(force: Bool = false) {
        guard !polling else { return }; polling = true; refreshing = force; lastPoll = Date()
        let prefs = preferences
        Task {
            var next = await engine.poll(prefs, force: force)
            next.balances = snapshot.balances
            snapshot = next; polling = false; refreshing = false
            notifications.process(snapshot: snapshot, preferences: preferences, accounts: accounts)
            if !preferences.accountsInitialized && !next.accounts.isEmpty {
                preferences.selectedAccounts = next.accounts.filter { $0.balanceKind != "unsupported" }.map(\.id)
                preferences.accountsInitialized = true; save()
            }
            persist(force: force)
        }
    }
    func save() {
        miniDisplayMetric = nil; lastRotation = Date(); rotationIndex = 0
        guard !testing else { onPreferencesChanged?(); return }
        do {
            try SharedStorage.write(preferences, name: "preferences.json", directory: SharedStorage.localDirectory)
        } catch { notice = "设置保存失败：" + error.localizedDescription }
        onPreferencesChanged?(); persist(force: true)
    }
    func toggleAccount(_ id: String, enabled: Bool) {
        if enabled { if !preferences.selectedAccounts.contains(id) { preferences.selectedAccounts.append(id) } }
        else { preferences.selectedAccounts.removeAll { $0 == id } }
        save()
        if enabled { refreshBalances() }
    }
    func refreshBalances() {
        guard !balanceRefreshing else { balanceRefreshPending = true; return }
        balanceRefreshing = true; lastBalance = Date()
        let selected = Set(preferences.selectedAccounts), manual = preferences.manualAccounts
        let path = preferences.ccPath, old = snapshot.balances
        Task {
            let records = (try? await Task.detached { try CCReader.providers(path: path) }.value) ?? []
            var results = old
            for record in records where selected.contains(record.account.id) {
                let result = await balances.query(record, custom: nil, previous: old.first { $0.id == record.account.id })
                results.removeAll { $0.id == result.id }; results.append(result)
            }
            for account in manual where selected.contains("manual:" + account.id) {
                let result = await balances.query(nil, custom: account, previous: old.first { $0.id == "manual:" + account.id })
                results.removeAll { $0.id == result.id }; results.append(result)
            }
            snapshot.balances = results; balanceRefreshing = false; persist(force: true)
            notifications.process(snapshot: snapshot, preferences: preferences, accounts: accounts)
            if balanceRefreshPending { balanceRefreshPending = false; refreshBalances() }
        }
    }
    private func persist(force: Bool = false) {
        guard !testing else { return }
        let signature = snapshot.tasks.map { $0.id + $0.state.rawValue }.joined() + preferences.selectedAccounts.joined() + "\(snapshot.usage.total)"
        // Throttle WidgetKit requests; the panel always uses the current in-memory snapshot.
        guard force || Date().timeIntervalSince(lastWidgetWrite) >= 60 && signature != lastWidgetSignature else { return }
        do {
            var shared = snapshot
            shared.theme = preferences.themeOptions
            shared.statistics = nil
            shared.accounts = selectedAccounts.map { account in var account = account; account.name = preferences.name(for: account); return account }
            shared.balances = snapshot.balances.filter { preferences.selectedAccounts.contains($0.id) }
            shared.tasks = Array(visibleTasks.prefix(40)).map { item in var item = item; item.sourcePath = nil; item.project = (item.project as NSString).lastPathComponent; return item }
            try SharedStorage.write(shared, name: "snapshot.json")
            WidgetCenter.shared.reloadTimelines(ofKind: SharedStorage.widgetKind)
            lastWidgetWrite = Date(); lastWidgetSignature = signature
        } catch { notice = "小组件快照写入失败：" + error.localizedDescription }
    }
    func detectAgents() { detectedAgents = AgentDetection.installed(preferences) }
    func finishOnboarding(agents: [AgentKind], preset: BoardPreset) {
        preferences.enabledAgents = agents.map(\.rawValue); preset.apply(to: &preferences)
        preferences.onboardingCompleted = true; save(); refresh(force: true)
    }
    func rotateMiniIfNeeded(now: Date = Date()) {
        let options = preferences.miniOptions
        let rotation = options.rotation ?? []
        guard preferences.compact, preferences.floatVisible, !miniDetailOpen, rotation.count > 1,
              now.timeIntervalSince(lastRotation) >= min(30, max(3, options.rotationInterval ?? 6)) else { return }
        let current = miniDisplayMetric ?? options.metric
        rotationIndex = ((rotation.firstIndex(of: current) ?? rotationIndex) + 1) % rotation.count
        miniDisplayMetric = rotation[rotationIndex]; lastRotation = now
    }
    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            let allowed = await notifications.requestPermission()
            preferences.alertOptions.enabled = allowed
            if !allowed { notice = "通知未获允许，可在系统设置 → 通知 → AgentBoard 中开启" }
        } else { preferences.alertOptions.enabled = false }
        save(); await updateNotificationStatus()
    }
    func updateNotificationStatus() async {
        guard !testing else { notificationStatus = "测试模式：不请求通知权限"; return }
        let status = await notifications.authorization()
        notificationStatus = status == .authorized ? "系统已允许通知" : (status == .denied ? "系统已拒绝，请在系统设置中允许" : "尚未授权，启用时将请求系统权限")
    }
    func sendTestNotification() async { await notifications.sendTest(sound: preferences.alertOptions.sound) }
}
