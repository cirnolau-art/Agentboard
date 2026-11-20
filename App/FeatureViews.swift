import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

extension BoardStore {
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "AgentBoard-配置.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try writeExport(ConfigurationDocument(preferences), to: url); notice = "配置已导出，不含密钥、API 接口和本机路径" } catch { notice = error.localizedDescription }
    }
    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000 else { throw ReaderError.message("配置文件过大") }
            let document = try JSONDecoder().decode(ConfigurationDocument.self, from: Data(contentsOf: url))
            let next = try document.applying(to: preferences, knownAccounts: Set(accounts.map(\.id)))
            try SharedStorage.write(preferences, name: "preferences.before-import.json", directory: SharedStorage.localDirectory)
            preferences = next; save(); refresh(force: true); notice = "配置已导入；账号接口、本机路径和通知授权保留。可恢复导入前配置。"
        } catch { notice = "配置导入失败：" + error.localizedDescription }
    }
    func restoreConfigurationBackup() {
        guard let backup = SharedStorage.read(BoardPreferences.self, name: "preferences.before-import.json", directory: SharedStorage.localDirectory) else { notice = "暂无导入前配置备份"; return }
        preferences = backup; save(); refresh(force: true); notice = "已恢复导入前配置"
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "AgentBoard-诊断.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try writeExport(SanitizedDiagnostics(snapshot: snapshot), to: url); notice = "脱敏诊断已导出：不含任务标题、路径、账号名称、接口或密钥" } catch { notice = error.localizedDescription }
    }
    private func writeExport<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct StatisticsView: View {
    @EnvironmentObject var store: BoardStore
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    @State private var period: UsagePeriod = .today
    @State private var groupByModel = false
    @State private var selectedAccount = ""
    private var buckets: [UsageBucket] { (store.snapshot.statistics?.buckets(for: period) ?? []).filter { selectedAccount.isEmpty || $0.accountID == selectedAccount } }
    private var total: Usage { buckets.reduce(into: Usage()) { $0.add($1.usage) } }
    private var days: [(String, Usage)] { Dictionary(grouping: buckets, by: \.day).map { ($0.key, $0.value.reduce(into: Usage()) { $0.add($1.usage) }) }.sorted { $0.0 < $1.0 } }
    private var groups: [(String, Usage)] { Dictionary(grouping: buckets, by: { groupByModel ? $0.model : $0.accountID }).map { ($0.key, $0.value.reduce(into: Usage()) { $0.add($1.usage) }) }.sorted { $0.1.cost > $1.1.cost } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("时间范围", selection: $period) { ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { store.refresh(force: true) }.disabled(store.refreshing)
            }
            Picker("API", selection: $selectedAccount) {
                Text("所有已记录的 API").tag("")
                ForEach(accountIDs, id: \.self) { Text(accountName($0)).tag($0) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 20) {
                        stat("输入 + 输出 token", BoardFormat.tokens(total.total)); Spacer()
                        stat("估算费用（USD）", BoardFormat.money(total.cost, unit: "USD")); Spacer()
                        stat("请求数", "\(total.requests)")
                    }.padding(16).background(palette.card, in: RoundedRectangle(cornerRadius: 14))
                    if buckets.isEmpty {
                        ContentUnavailableView("此范围暂无记录", systemImage: "chart.bar", description: Text("统计仅使用 CC Switch 的实际记录；没有记录的日期不会补造数据。"))
                    } else {
                        Chart {
                            ForEach(days, id: \.0) { day, usage in BarMark(x: .value("日期", String(day.suffix(5))), y: .value("费用 USD", usage.cost), width: .fixed(28)).foregroundStyle(palette.accent).cornerRadius(3) }
                        }.frame(height: 150).chartYAxisLabel("估算费用 USD").padding(12).background(palette.card, in: RoundedRectangle(cornerRadius: 12))
                        Picker("分组", selection: $groupByModel) { Text("按 API").tag(false); Text("按模型").tag(true) }.pickerStyle(.segmented).frame(width: 230)
                        ForEach(groups, id: \.0) { key, usage in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(groupByModel ? key : accountName(key)).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                                    Text("输入 " + BoardFormat.tokens(usage.input) + " · 输出 " + BoardFormat.tokens(usage.output) + " · 缓存读 " + BoardFormat.tokens(usage.cacheRead) + " / 写 " + BoardFormat.tokens(usage.cacheWrite)).font(.system(size: 9)).foregroundStyle(palette.muted)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 3) { Text(BoardFormat.money(usage.cost, unit: "USD")).foregroundStyle(palette.accent); Text(BoardFormat.tokens(usage.total) + " tokens · \(usage.requests) 次").font(.system(size: 9)).foregroundStyle(palette.muted) }
                            }.padding(12).background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    Text("按本机日期统计，缓存 token 单独列示；费用为 CC Switch 估算值，余额以供应商返回为准。").font(.caption).foregroundStyle(palette.muted)
                    ForEach(store.snapshot.statistics?.notes ?? [], id: \.self) { Text($0).font(.caption2).foregroundStyle(palette.muted) }
                    if let date = store.snapshot.statistics?.updatedAt { Text("统计更新于 " + date.formatted()).font(.caption2).foregroundStyle(palette.muted) }
                }
            }
        }.foregroundStyle(palette.text).tint(palette.accent).onAppear { period = store.preferences.usagePeriod ?? .today }
        .onChange(of: period) { _, value in store.preferences.usagePeriod = value; store.save() }
    }
    private func stat(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(palette.muted); Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7).monospacedDigit() } }
    private var accountIDs: [String] { Set(store.snapshot.accounts.map(\.id) + (store.snapshot.statistics?.buckets.map(\.accountID) ?? [])).sorted() }
    private func accountName(_ id: String) -> String {
        if let account = store.snapshot.accounts.first(where: { $0.id == id }) { return store.preferences.name(for: account) + " · " + account.appType }
        let kind = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let names = ["codex": "Codex", "dsh": "DeepSeek Harness", "qwen": "Qwen Code", "claude": "Claude Code", "workbuddy": "WorkBuddy"]
        let suffix = id.contains("_session") ? "会话记录（未关联供应商）" : "历史 API · " + id
        return (names[kind] ?? kind) + " · " + suffix
    }
}

struct ThemeEditor: View {
    @EnvironmentObject var store: BoardStore
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) { ForEach(ThemeSettings.presets, id: \.0) { name, theme in Button { store.preferences.themeOptions = theme; store.save() } label: { HStack(spacing: 4) { Circle().fill(BoardPalette(theme).accent).frame(width: 10, height: 10); Text(name) } }.controlSize(.small) } }
            colorRow("强调色", \.accent); colorRow("背景色", \.background); colorRow("卡片色", \.surface); colorRow("文字色", \.text); colorRow("辅助文字", \.muted)
            HStack { Image(systemName: "circle.inset.filled").foregroundStyle(palette.accent); Text("主题预览 · Lau Kachun").foregroundStyle(palette.text); Spacer(); Text("$12.34").foregroundStyle(palette.accent) }.padding(14).background(palette.card, in: RoundedRectangle(cornerRadius: 10)).padding(8).background(palette.background, in: RoundedRectangle(cornerRadius: 12))
            Text("颜色实时应用到浮窗、迷你模式与设置，小组件在下次刷新时同步。支持颜色选择器或 6 位 HEX。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func colorRow(_ title: String, _ path: WritableKeyPath<ThemeSettings, String>) -> some View {
        ThemeColorRow(title: title, path: path).environmentObject(store)
    }
}
private struct ThemeColorRow: View {
    @EnvironmentObject var store: BoardStore
    let title: String
    let path: WritableKeyPath<ThemeSettings, String>
    @State private var draft = ""
    @State private var invalid = false
    private var value: String { store.preferences.themeOptions[keyPath: path] }
    var body: some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { BoardPalette.color(value) }, set: { apply(BoardPalette.hex($0)) }), supportsOpacity: false)
            TextField("#RRGGBB", text: $draft).labelsHidden().font(.system(.caption, design: .monospaced)).frame(width: 85).onSubmit { apply(draft) }.foregroundStyle(invalid ? Color.orange : Color.primary)
            Button { apply(draft) } label: { Image(systemName: "checkmark") }.buttonStyle(.borderless).help("应用 HEX 颜色")
        }.onAppear { draft = "#" + value }.onChange(of: value) { _, v in draft = "#" + v; invalid = false }
    }
    private func apply(_ text: String) {
        guard let value = ThemeSettings.normalizedHex(text) else { invalid = true; return }
        var theme = store.preferences.themeOptions; theme[keyPath: path] = value; store.preferences.themeOptions = theme; store.save(); draft = "#" + value; invalid = false
    }
}

struct AlertSettingsView: View {
    @EnvironmentObject var store: BoardStore
    private func binding<T>(_ key: WritableKeyPath<AlertPreferences, T>) -> Binding<T> { Binding(get: { store.preferences.alertOptions[keyPath: key] }, set: { var a = store.preferences.alertOptions; a[keyPath: key] = $0; store.preferences.alertOptions = a; store.save() }) }
    var body: some View {
        Form {
            Section("系统通知") {
                Toggle("启用提醒", isOn: Binding(get: { store.preferences.alertOptions.enabled }, set: { value in Task { await store.setNotificationsEnabled(value) } }))
                Text(store.notificationStatus).font(.caption).foregroundStyle(.secondary)
                HStack { Button("发送测试提醒") { Task { await store.sendTestNotification() } }.disabled(!store.preferences.alertOptions.enabled); Button("打开系统通知设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) } }
                Toggle("播放提示音", isOn: binding(\.sound))
            }
            Section("任务状态") { Toggle("任务完成", isOn: binding(\.completed)); Toggle("任务失败", isOn: binding(\.failed)); Toggle("等待确认", isOn: binding(\.waiting)); Text("首次启动不补发历史任务；同一轮次、同一状态只提醒一次。").font(.caption).foregroundStyle(.secondary) }
            Section("静音时段") {
                Toggle("启用静音时段", isOn: binding(\.quietEnabled))
                HStack { Picker("从", selection: binding(\.quietStart)) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }; Picker("至", selection: binding(\.quietEnd)) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } } }
                Text("静音期间不发送，也不会结束后集中补发；开始和结束相同表示全天静音。").font(.caption).foregroundStyle(.secondary)
            }
            Section("API 低余额阈值") {
                if store.selectedAccounts.isEmpty { Text("先在 API 账号页选择需要监控的账号").foregroundStyle(.secondary) }
                ForEach(store.selectedAccounts) { account in ThresholdRow(account: account).environmentObject(store) }
                Text("只比较相同币种／单位的有效余额。恢复到阈值以上后，再次跌破才会重新提醒。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).task { await store.updateNotificationStatus() }
    }
}
private struct ThresholdRow: View {
    @EnvironmentObject var store: BoardStore
    let account: APIAccount
    private var unit: String { store.snapshot.balances.first { $0.id == account.id }?.unit ?? "USD" }
    private var value: BalanceThreshold { store.preferences.alertOptions.thresholds[account.id] ?? BalanceThreshold(amount: 5, unit: unit, enabled: false) }
    var body: some View {
        HStack {
            Toggle(store.preferences.name(for: account), isOn: Binding(get: { value.enabled }, set: { var v = value; v.enabled = $0; save(v) }))
            Spacer(minLength: 6)
            TextField("阈值", value: Binding(get: { value.amount }, set: { if $0.isFinite && $0 >= 0 { var v = value; v.amount = $0; save(v) } }), format: .number).labelsHidden().frame(width: 85)
            TextField("单位", text: Binding(get: { value.unit }, set: { var v = value; v.unit = String($0.uppercased().prefix(20)); save(v) })).labelsHidden().frame(width: 55)
        }
    }
    private func save(_ value: BalanceThreshold) { store.preferences.alertOptions.thresholds[account.id] = value; store.save() }
}

struct OnboardingView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.dismiss) var dismiss
    @State private var selected = Set<AgentKind>()
    @State private var preset: BoardPreset = .overview
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("配置你的 AI 工作台").font(.title2.bold())
            Text("选择监控对象和展示预设，之后随时可以调整。").foregroundStyle(.secondary)
            ForEach(AgentKind.allCases) { agent in
                Toggle(isOn: Binding(get: { selected.contains(agent) }, set: { if $0 { selected.insert(agent) } else { selected.remove(agent) } })) {
                    HStack { Label(agent.title, systemImage: agent.symbol); Spacer(); Text(store.detectedAgents.contains(agent) ? "已发现数据" : "未发现，可稍后指定目录").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Picker("展示预设", selection: $preset) { ForEach(BoardPreset.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            HStack { Button("保留现有设置") { store.preferences.onboardingCompleted = true; store.save(); dismiss() }; Spacer(); Button("开始使用") { store.finishOnboarding(agents: AgentKind.allCases.filter { selected.contains($0) }, preset: preset); dismiss() }.buttonStyle(.borderedProminent) }
        }.toggleStyle(.checkbox).buttonStyle(.bordered)
        .padding(28).frame(width: 540).foregroundStyle(palette.text).tint(palette.accent)
        .background(palette.background).preferredColorScheme(palette.isLight ? .light : .dark)
        .onAppear { store.detectAgents(); selected = Set(store.detectedAgents) }
    }
}
