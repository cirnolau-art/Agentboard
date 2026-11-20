import SwiftUI
import AppKit

struct MiniReadout {
    var value: String
    var caption: String
    var secondary: String?
    var warning: Bool
    var account: APIAccount?
    var balance: Balance?
    var task: AgentTask?
    init(snapshot: BoardSnapshot, preferences: BoardPreferences, accounts: [APIAccount], metric: MiniMetric? = nil) {
        let options = preferences.miniOptions
        let selectedAccount = accounts.first { $0.id == options.accountID } ?? accounts.first
        let selectedBalance = snapshot.balances.first { $0.id == selectedAccount?.id }
        let active = snapshot.tasks.filter { $0.state.active && preferences.enabledAgents.contains($0.agent.rawValue) }
        account = selectedAccount; balance = selectedBalance; task = active.first
        warning = active.contains { $0.state == .waiting }
        let amount = selectedBalance?.remaining.map { Self.shortMoney($0, unit: selectedBalance?.unit ?? "USD") } ?? "—"
        switch metric ?? options.metric {
        case .tasks:
            value = "\(active.count)"; caption = active.isEmpty ? "空闲" : "任务"
        case .tokens: value = BoardFormat.tokens(snapshot.usage.total); caption = "TOKENS"
        case .cost: value = Self.shortMoney(snapshot.usage.cost, unit: "USD"); caption = "今日费用"
        case .balance: value = amount; caption = "余额"; warning = selectedBalance?.error != nil || selectedBalance?.expired == true
        case .costAndBalance:
            value = Self.shortMoney(snapshot.usage.cost, unit: "USD"); caption = "费用 / 余额"; secondary = amount
            warning = selectedBalance?.error != nil || selectedBalance?.expired == true
        }
    }
    static func shortMoney(_ amount: Double, unit: String) -> String {
        guard abs(amount) >= 1000 else { return BoardFormat.money(amount, unit: unit) }
        let short = abs(amount) >= 1_000_000 ? String(format: "%.1fM", amount / 1_000_000) : String(format: "%.1fK", amount / 1000)
        let prefix = ["USD": "$", "CNY": "¥", "RMB": "¥", "EUR": "€"][unit.uppercased()]
        return prefix.map { $0 + short } ?? short
    }
}

struct MiniDetailView: View {
    @EnvironmentObject var store: BoardStore
    var onExpand: () -> Void
    var onClose: () -> Void
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    private var metric: MiniMetric { store.miniDisplayMetric ?? store.preferences.miniOptions.metric }
    private var readout: MiniReadout { MiniReadout(snapshot: store.snapshot, preferences: store.preferences, accounts: store.selectedAccounts, metric: metric) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 2) { Text("AgentBoard").font(.system(size: 13, weight: .semibold)); Text(BoardIdentity.author + " · v" + BoardIdentity.version).font(.system(size: 8)).foregroundStyle(palette.muted) }
                Spacer()
                Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("展开完整浮窗")
                Button { NotificationCenter.default.post(name: .boardShowSettings, object: nil) } label: { Image(systemName: "gearshape") }.help("设置")
                Button(action: onClose) { Image(systemName: "xmark") }.help("收起详情")
            }.buttonStyle(.plain).font(.system(size: 11)).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) { Text(metric.title).font(.system(size: 9)).foregroundStyle(palette.muted); Text(readout.value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit() }
                        if let secondary = readout.secondary { Text("/ " + secondary).font(.system(size: 17, design: .rounded)).foregroundStyle(palette.accent) }
                        Spacer(minLength: 0)
                        Menu {
                            ForEach(MiniMetric.allCases) { value in Button(value.title) { store.preferences.miniOptions.metric = value; store.save() } }
                            Divider()
                            Button("用量统计…") { NotificationCenter.default.post(name: .boardShowStatistics, object: nil) }
                        } label: { Image(systemName: "slider.horizontal.3") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    HStack {
                        summaryValue("今日 token", BoardFormat.tokens(store.snapshot.usage.total)); Spacer(minLength: 4)
                        summaryValue("今日估算费用", BoardFormat.money(store.snapshot.usage.cost, unit: "USD")); Spacer(minLength: 4)
                        summaryValue("缓存读取", BoardFormat.tokens(store.snapshot.usage.cacheRead))
                    }.padding(12).background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                    balances
                    Divider()
                    tasks
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.snapshot.health) { health in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(health.agent.title + " · " + (health.category?.title ?? (health.available ? "已连接" : "读取失败"))).font(.system(size: 9)).foregroundStyle(health.available && health.isStale != true ? palette.accent : .orange)
                                        if !health.available || health.isStale == true { Text(health.message).font(.system(size: 8)).foregroundStyle(.orange) }
                                        if let date = health.lastSuccessAt { Text("最近成功 " + date.formatted(date: .omitted, time: .standard)).font(.system(size: 8)).foregroundStyle(palette.muted) }
                                    }; Spacer(minLength: 2)
                                }
                            }
                            Button("重新检测") { store.refresh(force: true) }.buttonStyle(.plain).foregroundStyle(palette.accent)
                        }.padding(.top, 8)
                    } label: { Text("连接状态 · \(store.snapshot.health.filter { $0.available && $0.isStale != true }.count)/\(store.snapshot.health.count) 正常").font(.system(size: 9)).foregroundStyle(palette.muted) }
                }.padding(16)
            }.scrollIndicators(.automatic)
            VStack(alignment: .leading, spacing: 4) { HStack { Text("拖动移动 · 双击展开 · 右键切换指标"); Spacer(minLength: 0) }; Text(BoardIdentity.copyright).font(.system(size: 7)).lineLimit(1).minimumScaleFactor(0.8) }.font(.system(size: 8)).foregroundStyle(palette.muted).padding(.horizontal, 16).padding(.vertical, 10)
        }.background(palette.background.opacity(0.98), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.muted.opacity(0.18)))
        .preferredColorScheme(palette.isLight ? .light : .dark).foregroundStyle(palette.text).tint(palette.accent).ignoresSafeArea()
    }
    private var balances: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("API 余额").font(.system(size: 10, weight: .semibold)); Spacer(); Button("选择账号") { NotificationCenter.default.post(name: .boardShowAccounts, object: nil) }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(palette.accent) }
            if let account = readout.account {
                let balance = readout.balance
                HStack { Text(store.preferences.name(for: account)).font(.system(size: 11)).lineLimit(1); Spacer(minLength: 4); Text(balance?.remaining.map { BoardFormat.money($0, unit: balance?.unit ?? "USD") } ?? "—").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(palette.accent).lineLimit(1).minimumScaleFactor(0.7) }
                if let error = balance?.error { Text(error).font(.system(size: 8)).foregroundStyle(.orange).lineLimit(2) }
                else if let date = balance?.updatedAt { Text("余额更新于 " + date.formatted(date: .omitted, time: .shortened)).font(.system(size: 8)).foregroundStyle(balance?.expired == true ? .orange : palette.muted) }
                if store.selectedAccounts.count > 1 { DisclosureGroup("其他账号余额") { ForEach(store.selectedAccounts.filter { $0.id != account.id }) { other in HStack { Text(store.preferences.name(for: other)); Spacer(); let b = store.snapshot.balances.first { $0.id == other.id }; Text(b?.remaining.map { BoardFormat.money($0, unit: b?.unit ?? "USD") } ?? "—") }.font(.system(size: 9)).padding(.top, 5) } }.font(.system(size: 9)).foregroundStyle(palette.muted) }
            } else { Text("先在设置中勾选 API 账号").font(.system(size: 10)).foregroundStyle(palette.muted) }
        }
    }
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("当前任务").font(.system(size: 10, weight: .semibold)); Spacer(); Text("\(store.snapshot.running) 运行 · \(store.snapshot.waiting) 待确认").font(.system(size: 9)).foregroundStyle(palette.muted) }
            let active = store.visibleTasks.filter { $0.state.active }
            if active.isEmpty { Text("暂无正在执行的任务").font(.system(size: 10)).foregroundStyle(palette.muted) }
            ForEach(Array(active.prefix(3))) { task in
                Button { AgentNavigation.open(task) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: task.agent.symbol).foregroundStyle(palette.color(task.state)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(task.agent.title); Spacer(); Text(task.state.title).foregroundStyle(palette.color(task.state)) }.font(.system(size: 9)).foregroundStyle(palette.muted)
                            Text(task.title).font(.system(size: 11, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                            if let tokens = task.sessionTokens { Text("会话累计 " + BoardFormat.tokens(tokens) + " tokens").font(.system(size: 8)).foregroundStyle(palette.muted) }
                        }
                        Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(palette.muted)
                    }
                }.buttonStyle(.plain).help(AgentNavigation.sessionURL(task) != nil ? "打开对应 Codex 会话" : "定位任务数据")
            }
        }
    }
    private func summaryValue(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 8)).foregroundStyle(palette.muted); Text(value).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7) } }
}

struct MiniBadgeView: View {
    @EnvironmentObject var store: BoardStore
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    private var options: MiniPreferences { var options = store.preferences.miniOptions; options.metric = store.miniDisplayMetric ?? options.metric; return options }
    private var readout: MiniReadout { MiniReadout(snapshot: store.snapshot, preferences: store.preferences, accounts: store.selectedAccounts, metric: options.metric) }
    private var accent: Color { readout.warning ? .orange : palette.accent }
    var body: some View {
        Group {
            if options.shape == .ring { ring }
            else { capsule }
        }
        .padding(4)
        .frame(width: MiniGeometry.size(options).width, height: MiniGeometry.size(options).height)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(options.metric.title + " " + readout.value + (readout.secondary.map { "，余额 " + $0 } ?? ""))
        .scaleEffect(pulse ? 0.94 : 1)
        .animation(options.animations != false && !reduceMotion ? .easeInOut(duration: 0.2) : nil, value: readout.value)
        .onChange(of: store.snapshot.running) { _, _ in signalChange() }
        .onChange(of: store.snapshot.waiting) { _, _ in signalChange() }
    }
    private func signalChange() {
        guard options.animations != false && !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.12)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pulse = false } }
    }
    private var ring: some View {
        ZStack {
            Circle().fill(palette.background.opacity(store.preferences.opacity))
            Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1)
            // A status border, not a percentage: no quota is assumed for token totals.
            Circle().inset(by: 1.7).strokeBorder(accent.opacity(0.85), lineWidth: 2.2)
            if let secondary = readout.secondary {
                VStack(spacing: 2) {
                    Text(readout.value).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(palette.accent)
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5).padding(.horizontal, 4)
                    Text(secondary).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(palette.text)
                }.padding(.horizontal, 6)
            } else {
                VStack(spacing: 1) {
                    Text(readout.value).font(.system(size: options.metric == .tasks ? 17 : 12, weight: .semibold, design: .rounded)).foregroundStyle(palette.text)
                    Text(readout.caption).font(.system(size: options.metric == .tokens ? 5.5 : 7, weight: .medium)).foregroundStyle(accent)
                }.padding(.horizontal, 5)
            }
        }
        .frame(width: options.safeDiameter, height: options.safeDiameter)
        .overlay(alignment: .topTrailing) { if readout.warning { Circle().fill(.orange).frame(width: 6, height: 6).overlay(Circle().stroke(palette.background, lineWidth: 1)).offset(x: -1, y: 1) } }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .lineLimit(1).minimumScaleFactor(0.60).monospacedDigit()
    }
    private var capsule: some View {
        HStack(spacing: 7) {
            Image(systemName: options.metric.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            if let secondary = readout.secondary {
                Text(readout.value).foregroundStyle(palette.accent)
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 12)
                Text(secondary).foregroundStyle(palette.text)
            } else {
                Text(readout.value).foregroundStyle(palette.text)
                Spacer(minLength: 0)
                Text(options.metric == .tokens ? "TOK" : readout.caption).font(.system(size: 8)).foregroundStyle(accent)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        .padding(.horizontal, 11)
        .frame(width: MiniGeometry.size(options).width - 8, height: MiniGeometry.size(options).height - 8)
        .background(palette.background.opacity(store.preferences.opacity), in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .lineLimit(1).minimumScaleFactor(0.65)
    }
}

