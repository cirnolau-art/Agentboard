import Foundation

enum ConnectionCategory: String, Codable {
    case connected, notInstalled, missingData, busy, incompatible, unreadable
    var title: String {
        switch self { case .connected: return "已连接"; case .notInstalled: return "未安装／未发现目录"; case .missingData: return "等待数据"; case .busy: return "数据库忙碌"; case .incompatible: return "格式不兼容"; case .unreadable: return "读取失败" }
    }
}
enum UsagePeriod: String, Codable, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }
    var title: String { switch self { case .today: return "今日"; case .week: return "近 7 天"; case .month: return "本月" } }
    func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self { case .today: return today; case .week: return calendar.date(byAdding: .day, value: -6, to: today)!; case .month: return calendar.date(from: calendar.dateComponents([.year, .month], from: now))! }
    }
}
struct UsageBucket: Codable, Identifiable {
    var day: String
    var accountID: String
    var model: String
    var usage: Usage
    var id: String { day + "|" + accountID + "|" + model }
}
struct UsageStatistics: Codable {
    var updatedAt: Date
    var buckets: [UsageBucket]
    var sessionUsage: [String: Usage]
    var notes: [String]
    func buckets(for period: UsagePeriod, now: Date = Date()) -> [UsageBucket] {
        let start = BoardFormat.day(period.start(now: now)), end = BoardFormat.day(now)
        return buckets.filter { $0.day >= start && $0.day <= end }
    }
    func total(for period: UsagePeriod, now: Date = Date()) -> Usage {
        buckets(for: period, now: now).reduce(into: Usage()) { $0.add($1.usage) }
    }
}
struct BalanceThreshold: Codable, Equatable {
    var amount: Double
    var unit: String
    var enabled: Bool = true
}
struct AlertPreferences: Codable, Equatable {
    var enabled = false
    var completed = true
    var failed = true
    var waiting = true
    var sound = false
    var quietEnabled = false
    var quietStart = 22
    var quietEnd = 8
    var thresholds: [String: BalanceThreshold] = [:]
    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietStart == quietEnd { return true }
        return quietStart < quietEnd ? hour >= quietStart && hour < quietEnd : hour >= quietStart || hour < quietEnd
    }
}
enum BoardPreset: String, CaseIterable, Identifiable {
    case focus, costs, overview
    var id: String { rawValue }
    var title: String { switch self { case .focus: return "专注任务"; case .costs: return "关注费用"; case .overview: return "综合概览" } }
    func apply(to preferences: inout BoardPreferences) {
        switch self {
        case .focus: preferences.moduleOrder = ["tasks", "usage", "balances"]; preferences.hiddenModules = []; preferences.showRecentCompleted = false; preferences.menuMetric = "tasks"; preferences.miniOptions.metric = .tasks
        case .costs: preferences.moduleOrder = ["balances", "usage", "tasks"]; preferences.hiddenModules = []; preferences.showRecentCompleted = true; preferences.menuMetric = "balance"; preferences.miniOptions.metric = .costAndBalance
        case .overview: preferences.moduleOrder = ["usage", "balances", "tasks"]; preferences.hiddenModules = []; preferences.showRecentCompleted = true; preferences.menuMetric = "tasks"; preferences.miniOptions.metric = .tasks
        }
    }
}
