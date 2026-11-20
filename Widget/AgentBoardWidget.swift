import SwiftUI
import WidgetKit
import AppIntents

enum WidgetTheme: String, AppEnum {
    case overview, balances, tasks, usage
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "展示主题"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.overview: "综合概览", .balances: "API 余额", .tasks: "Agent 任务", .usage: "今日用量"]
}

enum WidgetAgent: String, AppEnum {
    case all, codex, workbuddy, dsh, qwen, claude, custom
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.all: "所有已启用", .codex: "Codex", .workbuddy: "WorkBuddy", .dsh: "DeepSeek Harness", .qwen: "Qwen Code", .claude: "Claude Code", .custom: "其他 Agent"]
}

struct WidgetAccount: AppEntity {
    var id: String
    var name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "API 账号"
    static var defaultQuery = WidgetAccountQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct WidgetAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetAccount] { try await suggestedEntities().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [WidgetAccount] {
        let snapshot = SharedStorage.read(BoardSnapshot.self, name: "snapshot.json") ?? .empty
        return snapshot.accounts.map { WidgetAccount(id: $0.id, name: $0.name) }
    }
}

struct BoardWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "AgentBoard 小组件"
    static var description = IntentDescription("独立选择展示主题、API 账号和 agent。")
    @Parameter(title: "展示主题", default: .overview) var theme: WidgetTheme
    @Parameter(title: "API 账号（留空显示所选账号）") var account: WidgetAccount?
    @Parameter(title: "Agent", default: .all) var agent: WidgetAgent
}

struct BoardEntry: TimelineEntry {
    var date: Date
    var configuration: BoardWidgetIntent
    var snapshot: BoardSnapshot
    var preferences: BoardPreferences
}
struct BoardProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BoardEntry { BoardEntry(date: Date(), configuration: BoardWidgetIntent(), snapshot: .empty, preferences: BoardPreferences()) }
    func snapshot(for configuration: BoardWidgetIntent, in context: Context) async -> BoardEntry { entry(configuration) }
    func timeline(for configuration: BoardWidgetIntent, in context: Context) async -> Timeline<BoardEntry> { Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(900))) }
    func entry(_ intent: BoardWidgetIntent) -> BoardEntry {
        BoardEntry(date: Date(), configuration: intent, snapshot: SharedStorage.read(BoardSnapshot.self, name: "snapshot.json") ?? .empty, preferences: BoardPreferences())
    }
}

struct BoardWidgetView: View {
    @Environment(\.widgetFamily) var systemFamily
    let entry: BoardEntry
    var previewFamily: WidgetFamily? = nil
    private var family: WidgetFamily { previewFamily ?? systemFamily }
    private var palette: BoardPalette { BoardPalette(entry.snapshot.theme ?? ThemeSettings()) }
    private var mint: Color { palette.accent }
    private var tasks: [AgentTask] { entry.snapshot.tasks.filter { entry.configuration.agent == .all || $0.agent.rawValue == entry.configuration.agent.rawValue } }
    private var accounts: [APIAccount] { entry.snapshot.accounts.filter { entry.configuration.account == nil || $0.id == entry.configuration.account?.id } }
    private var usage: Usage {
        if let id = entry.configuration.account?.id { return entry.snapshot.accounts.first { $0.id == id }?.usage ?? Usage() }
        return entry.snapshot.usage
    }
    private var title: String { switch entry.configuration.theme { case .overview: return "AgentBoard"; case .balances: return "API 余额"; case .tasks: return "Agent 任务"; case .usage: return "今日用量" } }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 10 : 13) {
            HStack { Image(systemName: "square.stack.3d.up.fill").foregroundStyle(mint); Text(title).fontWeight(.semibold); Spacer(minLength: 0); if family != .systemSmall { Text("本机快照").font(.system(size: 9)).foregroundStyle(palette.text.opacity(0.45)) } }.font(.system(size: 11))
            if entry.snapshot.updatedAt == .distantPast {
                Spacer(minLength: 0); Text("打开应用开始监控").font(.system(size: 13, weight: .medium)); Text("选择 API 账号与 agent").font(.system(size: 10)).foregroundStyle(palette.text.opacity(0.5)); Spacer(minLength: 0)
            } else if family == .systemSmall { small }
            else if family == .systemMedium { medium }
            else { large }
            Spacer(minLength: 0)
            HStack(spacing: 3) { Circle().fill(Date().timeIntervalSince(entry.snapshot.updatedAt) > 300 ? .orange : mint).frame(width: 4, height: 4); Text("更新于"); if entry.snapshot.updatedAt != .distantPast { Text(entry.snapshot.updatedAt, style: Date().timeIntervalSince(entry.snapshot.updatedAt) > 86400 ? .date : .time) } else { Text("等待连接") }; Spacer(minLength: 0) }.font(.system(size: 8)).foregroundStyle(palette.text.opacity(0.45))
        }
        .foregroundStyle(palette.text)
        .containerBackground(for: .widget) { LinearGradient(colors: [palette.card, palette.background], startPoint: .topLeading, endPoint: .bottomTrailing) }
        .widgetURL(URL(string: "agentboard://open"))
    }
    @ViewBuilder private var small: some View {
        switch entry.configuration.theme {
        case .balances:
            if let account = accounts.first { balance(account, large: true) } else { hint("先在应用中选择账号") }
        case .usage:
            usage(large: true)
        case .overview, .tasks:
            activity(large: true)
            if let task = tasks.first { Text(task.title).font(.system(size: 10)).lineLimit(2).foregroundStyle(palette.text.opacity(0.7)).privacySensitive() }
            else { hint("暂无任务") }
        }
    }
    @ViewBuilder private var medium: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                if entry.configuration.theme == .balances { if let account = accounts.first { balance(account, large: true) } else { hint("先在应用中选择账号") } }
                else if entry.configuration.theme == .usage { usage(large: true) }
                else { activity(large: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(palette.text.opacity(0.1)).frame(width: 1)
            VStack(alignment: .leading, spacing: 10) {
                if entry.configuration.theme == .balances { ForEach(Array(accounts.dropFirst().prefix(2))) { balance($0) }; if accounts.count == 1 { hint("独立账号余额"); usage() } }
                else if entry.configuration.theme == .usage { cacheMetrics }
                else { ForEach(Array(tasks.prefix(2))) { taskRow($0) }; if tasks.isEmpty { hint("所有任务会显示在这里") } }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var large: some View {
        if entry.configuration.theme == .overview {
            HStack(alignment: .top) { activity(large: true); Spacer(); usage() }
            separator
            if let account = accounts.first { balance(account) }
            separator
            ForEach(Array(tasks.prefix(3))) { taskRow($0) }
            if tasks.isEmpty { hint("暂无任务") }
        } else if entry.configuration.theme == .balances {
            ForEach(Array(accounts.prefix(4))) { balance($0); if $0.id != accounts.prefix(4).last?.id { separator } }
            if accounts.isEmpty { hint("先在应用中选择账号") }
        } else if entry.configuration.theme == .usage {
            usage(large: true); separator; cacheMetrics
            HStack { Text("估算费用"); Spacer(); Text(BoardFormat.money(usage.cost, unit: "USD")).foregroundStyle(mint) }.font(.system(size: 13))
            hint("以 CC Switch 已记录的数据为准")
        } else {
            activity(large: true); separator
            ForEach(Array(tasks.prefix(5))) { taskRow($0) }
            if tasks.isEmpty { hint("暂无任务") }
        }
    }
    private func activity(large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) { Text("\(tasks.filter { $0.state == .running }.count)").font(.system(size: large ? 34 : 24, weight: .medium, design: .rounded)); Text("执行中").font(.system(size: 10)).foregroundStyle(palette.text.opacity(0.6)) }
            let waiting = tasks.filter { $0.state == .waiting }.count
            Text(waiting > 0 ? "\(waiting) 个等待确认" : "暂无待确认").font(.system(size: 10)).foregroundStyle(waiting > 0 ? .orange : mint)
        }
    }
    private func usage(large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("输入 + 输出").font(.system(size: 9)).foregroundStyle(palette.text.opacity(0.5))
            Text(BoardFormat.tokens(usage.total)).font(.system(size: large ? 30 : 22, weight: .medium, design: .rounded)).monospacedDigit()
            Text("输入 \(BoardFormat.tokens(usage.input)) · 输出 \(BoardFormat.tokens(usage.output))").font(.system(size: 9)).foregroundStyle(mint).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
    private var cacheMetrics: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("缓存读取 " + BoardFormat.tokens(usage.cacheRead))
            Text("缓存写入 " + BoardFormat.tokens(usage.cacheWrite))
            Text("\(usage.requests) 次请求")
        }.font(.system(size: 10)).foregroundStyle(palette.text.opacity(0.65))
    }
    private func balance(_ account: APIAccount, large: Bool = false) -> some View {
        let balance = entry.snapshot.balances.first { $0.id == account.id }
        return VStack(alignment: .leading, spacing: 4) {
            Text(entry.preferences.name(for: account)).font(.system(size: 10)).foregroundStyle(palette.text.opacity(0.65)).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(balance?.remaining.map { BoardFormat.money($0, unit: balance?.unit ?? "USD") } ?? "—").font(.system(size: large ? 27 : 19, weight: .medium, design: .rounded)).foregroundStyle(mint).lineLimit(1).minimumScaleFactor(0.65)
                if !large { Spacer(minLength: 0); if balance?.error != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) } }
            }
            if let error = balance?.error, large { Text(error).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2) }
            else if let date = balance?.updatedAt { HStack(spacing: 3) { Text(balance?.isManual == true ? "手动余额" : "查询于"); Text(date, style: .time) }.font(.system(size: 8)).foregroundStyle(palette.text.opacity(0.4)) }
        }
    }
    private func taskRow(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(task.agent.title).foregroundStyle(palette.text.opacity(0.5)); Spacer(minLength: 3); Text(task.state.title).foregroundStyle(palette.color(task.state)) }.font(.system(size: 9))
            Text(task.title).font(.system(size: 11, weight: .medium)).lineLimit(1).privacySensitive()
        }
    }
    private func hint(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundStyle(palette.text.opacity(0.5)).fixedSize(horizontal: false, vertical: true) }
    private var separator: some View { Rectangle().fill(palette.text.opacity(0.09)).frame(height: 1) }
}

#if WIDGET_EXTENSION
@main struct AgentBoardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SharedStorage.widgetKind, intent: BoardWidgetIntent.self, provider: BoardProvider()) { entry in BoardWidgetView(entry: entry) }
            .configurationDisplayName("AgentBoard")
            .description("API 余额、token 用量和 AI agent 任务状态。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
#endif
