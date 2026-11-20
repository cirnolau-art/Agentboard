import Foundation

enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case codex, workbuddy, dsh, qwen, claude, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .codex: return "Codex"; case .workbuddy: return "WorkBuddy"; case .dsh: return "DeepSeek Harness"; case .qwen: return "Qwen Code"; case .claude: return "Claude Code"; case .custom: return "其他 Agent" }
    }
    var symbol: String {
        switch self { case .codex: return "terminal"; case .workbuddy: return "person.2"; case .dsh: return "sparkle"; case .qwen: return "bolt"; case .claude: return "sun.max"; case .custom: return "cpu" }
    }
    var defaultPath: String {
        switch self { case .codex: return "~/.codex"; case .workbuddy: return "~/.workbuddy"; case .dsh: return "~/.dsh"; case .qwen: return "~/.qwen"; case .claude: return "~/.claude"; case .custom: return "~/.agentboard/events" }
    }
}

enum TaskState: String, Codable {
    case running, waiting, completed, failed, interrupted, idle, unknown
    var title: String {
        switch self { case .running: return "执行中"; case .waiting: return "等待确认"; case .completed: return "已完成"; case .failed: return "失败"; case .interrupted: return "已中断"; case .idle: return "空闲"; case .unknown: return "状态待确认" }
    }
    var active: Bool { self == .running || self == .waiting }
    var rank: Int { switch self { case .waiting: return 0; case .running: return 1; case .failed: return 2; case .unknown: return 3; default: return 4 } }
}

struct AgentTask: Codable, Identifiable {
    var id: String
    var agent: AgentKind
    var title: String
    var project: String
    var state: TaskState
    var updatedAt: Date
    var startedAt: Date?
    var source: String
    var sourcePath: String?
    var detail: String = ""
    var sessionTokens: Int64?
    var requestUsage: Usage?
}

struct AgentHealth: Codable, Identifiable {
    var agent: AgentKind
    var available: Bool
    var message: String
    var isStale: Bool?
    var checkedAt: Date?
    var lastSuccessAt: Date?
    var category: ConnectionCategory?
    var id: String { agent.rawValue }
}

struct Usage: Codable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var cost: Double = 0
    var requests: Int = 0
    var latestAt: Date?
    var total: Int64 { input + output }
    mutating func add(_ other: Usage) {
        input += other.input; output += other.output; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
        cost += other.cost; requests += other.requests
        if let d = other.latestAt, d > (latestAt ?? .distantPast) { latestAt = d }
    }
}

struct APIAccount: Codable, Identifiable {
    var id: String
    var providerID: String
    var appType: String
    var name: String
    var balanceKind: String
    var current: Bool
    var usage: Usage = Usage()
}

struct Balance: Codable, Identifiable {
    var id: String
    var remaining: Double?
    var unit: String = "USD"
    var updatedAt: Date?
    var attemptedAt: Date?
    var error: String?
    var isManual: Bool = false
    var expired: Bool { updatedAt.map { Date().timeIntervalSince($0) > 900 } ?? true }
}

struct BoardSnapshot: Codable {
    var updatedAt: Date = .distantPast
    var usageUpdatedAt: Date?
    var usageDay: String = ""
    var usage: Usage = Usage()
    var accounts: [APIAccount] = []
    var balances: [Balance] = []
    var tasks: [AgentTask] = []
    var health: [AgentHealth] = []
    var issues: [String] = []
    var statistics: UsageStatistics?
    var theme: ThemeSettings?
    var running: Int { tasks.filter { $0.state == .running }.count }
    var waiting: Int { tasks.filter { $0.state == .waiting }.count }
    static var empty: BoardSnapshot { BoardSnapshot() }
}

struct ManualAccount: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var endpoint: String = ""
    var amountPath: String = "remaining"
    var unit: String = "USD"
    var staticAmount: Double?
}

enum MiniMetric: String, Codable, CaseIterable, Identifiable {
    case tasks, tokens, cost, balance, costAndBalance
    var id: String { rawValue }
    var title: String {
        switch self { case .tasks: return "当前任务"; case .tokens: return "今日 token"; case .cost: return "今日估算费用"; case .balance: return "API 余额"; case .costAndBalance: return "今日费用 + 余额" }
    }
    var symbol: String {
        switch self { case .tasks: return "play.fill"; case .tokens: return "chart.bar.fill"; case .cost: return "chart.line.uptrend.xyaxis"; case .balance: return "creditcard.fill"; case .costAndBalance: return "arrow.up.arrow.down" }
    }
}

enum MiniShape: String, Codable, CaseIterable, Identifiable {
    case ring, capsule
    var id: String { rawValue }
    var title: String { self == .ring ? "小圆环" : "小胶囊" }
}

struct MiniPreferences: Codable, Equatable {
    var metric: MiniMetric = .tasks
    var shape: MiniShape = .ring
    var diameter: Double = 48
    var accountID: String?
    var rotation: [MiniMetric]?
    var rotationInterval: Double?
    var animations: Bool?
    var safeDiameter: Double { min(56, max(40, diameter.isFinite ? diameter : 48)) }
}

struct BoardPreferences: Codable {
    var enabledAgents: [String] = ["codex", "workbuddy", "dsh", "qwen"]
    var agentPaths: [String: String] = [:]
    var selectedAccounts: [String] = []
    var accountsInitialized: Bool = false
    var accountAliases: [String: String] = [:]
    var manualAccounts: [ManualAccount] = []
    var pinned: Bool = true
    var allSpaces: Bool = true
    var floatVisible: Bool = true
    var compact: Bool = false
    // Optional so settings saved before the compact badge was introduced remain decodable.
    var mini: MiniPreferences?
    var theme: ThemeSettings?
    var alerts: AlertPreferences?
    var usagePeriod: UsagePeriod?
    var onboardingCompleted: Bool?
    var opacity: Double = 0.97
    var fontScale: Double = 1
    var menuMetric: String = "tasks"
    var balanceInterval: Double = 300
    var usageInterval: Double = 15
    var taskInterval: Double = 3
    var showRecentCompleted: Bool = true
    var moduleOrder: [String] = ["usage", "balances", "tasks"]
    var hiddenModules: [String] = []
    var ccPath: String = "~/.cc-switch/cc-switch.db"
    var miniOptions: MiniPreferences {
        get { mini ?? MiniPreferences() }
        set { mini = newValue }
    }
    var themeOptions: ThemeSettings { get { theme ?? ThemeSettings() } set { theme = newValue } }
    var alertOptions: AlertPreferences { get { alerts ?? AlertPreferences() } set { alerts = newValue } }
    func path(for agent: AgentKind) -> String { ((agentPaths[agent.rawValue] ?? agent.defaultPath) as NSString).expandingTildeInPath }
    func name(for account: APIAccount) -> String {
        let alias = accountAliases[account.id] ?? ""
        return alias.isEmpty ? account.name : alias
    }
}

enum BoardFormat {
    static func tokens(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
    static func money(_ value: Double, unit: String) -> String {
        let symbol = ["USD": "$", "CNY": "¥", "RMB": "¥", "EUR": "€" ][unit.uppercased()]
        return symbol.map { "\($0)\(String(format: "%.2f", value))" } ?? "\(String(format: "%.2f", value)) \(unit)"
    }
    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f.string(from: date)
    }
}
