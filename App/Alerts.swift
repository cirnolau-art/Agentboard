import Foundation
import UserNotifications

struct BoardAlert: Identifiable {
    var id: String
    var title: String
    var body: String
    var taskID: String?
}
struct AlertLedger: Codable {
    var delivered: [String: Date] = [:]
    var lowBalances: [String: Bool] = [:]
}
struct AlertEvaluator {
    var ledger = AlertLedger()
    private var previous: [String: (TaskState, Date?)] = [:]
    private var initialized = false
    mutating func evaluate(snapshot: BoardSnapshot, preferences: BoardPreferences, accounts: [APIAccount], now: Date = Date()) -> [BoardAlert] {
        let settings = preferences.alertOptions
        var alerts: [BoardAlert] = []
        defer {
            for task in snapshot.tasks { previous[task.id] = (task.state, task.startedAt) }
            initialized = true
            ledger.delivered = ledger.delivered.filter { now.timeIntervalSince($0.value) < 30 * 86400 }
            if ledger.delivered.count > 2000 { ledger.delivered = Dictionary(uniqueKeysWithValues: ledger.delivered.sorted { $0.value > $1.value }.prefix(2000).map { ($0.key, $0.value) }) }
        }
        for task in snapshot.tasks where preferences.enabledAgents.contains(task.agent.rawValue) {
            guard initialized, previous[task.id]?.0 != task.state || previous[task.id]?.1 != task.startedAt else { continue }
            let selected = task.state == .completed && settings.completed || task.state == .failed && settings.failed || task.state == .waiting && settings.waiting
            guard selected, now.timeIntervalSince(task.updatedAt) < 120 else { continue }
            let turn = task.startedAt?.timeIntervalSince1970 ?? task.updatedAt.timeIntervalSince1970
            let key = task.id + ":" + String(turn) + ":" + task.state.rawValue
            guard ledger.delivered[key] == nil else { continue }
            ledger.delivered[key] = now
            if settings.enabled && !settings.isQuiet(at: now) {
                alerts.append(BoardAlert(id: UUID().uuidString, title: task.agent.title + " · " + task.state.title, body: task.title, taskID: task.id))
            }
        }
        if settings.enabled {
            for account in accounts where preferences.selectedAccounts.contains(account.id) {
                guard let threshold = settings.thresholds[account.id], threshold.enabled, threshold.amount.isFinite, threshold.amount >= 0,
                      let balance = snapshot.balances.first(where: { $0.id == account.id }), balance.error == nil, !balance.expired,
                      balance.unit.uppercased() == threshold.unit.uppercased(), let amount = balance.remaining, amount.isFinite else { continue }
                let key = account.id + ":" + threshold.unit.uppercased() + ":" + String(threshold.amount)
                let below = amount <= threshold.amount
                if below && ledger.lowBalances[key] != true && !settings.isQuiet(at: now) {
                    alerts.append(BoardAlert(id: UUID().uuidString, title: "API 余额不足", body: preferences.name(for: account) + "：" + BoardFormat.money(amount, unit: balance.unit) + "，低于或等于阈值 " + BoardFormat.money(threshold.amount, unit: threshold.unit)))
                }
                ledger.lowBalances[key] = below
            }
        }
        return alerts
    }
}

@MainActor final class BoardNotifications: NSObject, UNUserNotificationCenterDelegate {
    private var evaluator: AlertEvaluator
    private let testing: Bool
    var onError: ((String) -> Void)?
    init(testing: Bool = false) {
        self.testing = testing
        var evaluator = AlertEvaluator()
        if !testing { evaluator.ledger = SharedStorage.read(AlertLedger.self, name: "notification-ledger.json", directory: SharedStorage.localDirectory) ?? AlertLedger() }
        self.evaluator = evaluator
        super.init()
        if !testing { UNUserNotificationCenter.current().delegate = self }
    }
    func authorization() async -> UNAuthorizationStatus { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    func requestPermission() async -> Bool {
        guard !testing else { return false }
        do { return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { onError?("通知授权失败：" + error.localizedDescription); return false }
    }
    func process(snapshot: BoardSnapshot, preferences: BoardPreferences, accounts: [APIAccount]) {
        let before = evaluator.ledger
        let alerts = evaluator.evaluate(snapshot: snapshot, preferences: preferences, accounts: accounts)
        guard !testing else { return }
        if before.delivered != evaluator.ledger.delivered || before.lowBalances != evaluator.ledger.lowBalances {
            do { try SharedStorage.write(evaluator.ledger, name: "notification-ledger.json", directory: SharedStorage.localDirectory) }
            catch { onError?("提醒记录保存失败：" + error.localizedDescription) }
        }
        guard preferences.alertOptions.enabled, !alerts.isEmpty else { return }
        Task {
            guard await authorization() == .authorized else { return }
            for alert in alerts { await send(alert, sound: preferences.alertOptions.sound) }
        }
    }
    func sendTest(sound: Bool) async {
        guard await authorization() == .authorized else { onError?("请先在系统设置中允许 AgentBoard 通知"); return }
        await send(BoardAlert(id: UUID().uuidString, title: "AgentBoard 测试提醒", body: "任务提醒与低余额提醒已就绪。"), sound: sound)
    }
    private func send(_ alert: BoardAlert, sound: Bool) async {
        let content = UNMutableNotificationContent(); content.title = alert.title; content.body = alert.body
        if sound { content.sound = .default }
        if let id = alert.taskID { content.userInfo = ["taskID": id] }
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)) }
        catch { onError?("通知发送失败：" + error.localizedDescription) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { NotificationCenter.default.post(name: .boardShowPanel, object: nil) }
    }
}
