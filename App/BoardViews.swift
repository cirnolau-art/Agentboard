import SwiftUI
import AppKit

enum BoardStyle {
    static let background = Color(red: 0.055, green: 0.075, blue: 0.105)
    static let card = Color(red: 0.095, green: 0.12, blue: 0.155)
    static let accent = Color(red: 0.50, green: 0.91, blue: 0.77)
    static let muted = Color(red: 0.57, green: 0.65, blue: 0.71)
    static func color(_ state: TaskState) -> Color {
        switch state { case .running: return accent; case .waiting: return .orange; case .failed: return .red; case .completed: return .cyan; default: return muted }
    }
}

struct BoardCard<Content: View>: View {
    @EnvironmentObject var store: BoardStore
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(palette.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.055))) }
}

struct DashboardView: View {
    @EnvironmentObject var store: BoardStore
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    var popover = false
    @State private var showAllTasks = false
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Group {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            overview
                            if geometry.size.width >= 620 {
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(spacing: 14) { ForEach(store.preferences.moduleOrder.filter { $0 != "tasks" && !store.preferences.hiddenModules.contains($0) }, id: \.self) { module($0) } }.frame(maxWidth: .infinity)
                                    if !store.preferences.hiddenModules.contains("tasks") { tasksCard.frame(maxWidth: .infinity) }
                                }
                            } else {
                                ForEach(store.preferences.moduleOrder.filter { !store.preferences.hiddenModules.contains($0) }, id: \.self) { module($0) }
                            }
                            if let notice = store.notice { Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            ForEach(store.snapshot.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            footer
                        }.padding(.horizontal, 16).padding(.bottom, 16)
                    }.scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background.opacity(store.preferences.opacity))
        }
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .foregroundStyle(palette.text)
        .ignoresSafeArea()
        .tint(palette.accent)
        .font(.system(size: 12 * store.preferences.fontScale))
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 19 * store.preferences.fontScale, weight: .medium)).foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentBoard").font(.system(size: 15 * store.preferences.fontScale, weight: .semibold)).foregroundStyle(palette.text)
                Text(BoardIdentity.author + " · v" + BoardIdentity.version).font(.system(size: 10 * store.preferences.fontScale)).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 4)
            Button { store.refresh(force: true); store.refreshBalances() } label: { Image(systemName: "arrow.clockwise").rotationEffect(.degrees(store.refreshing ? 180 : 0)) }.help("刷新用量和余额").disabled(store.refreshing)
            if !popover {
                Button { store.preferences.pinned.toggle(); store.save() } label: { Image(systemName: store.preferences.pinned ? "pin.fill" : "pin") }.help("窗口置顶").foregroundStyle(store.preferences.pinned ? palette.accent : palette.muted)
            }
            Menu {
                Button(popover ? "显示浮窗" : "隐藏浮窗") { NotificationCenter.default.post(name: popover ? .boardShowPanel : .boardHidePanel, object: nil) }
                Button(store.preferences.compact ? "展开浮窗" : "收起为迷你模式") { store.preferences.compact.toggle(); store.save() }
                Divider()
                Button("设置…") { NotificationCenter.default.post(name: .boardShowSettings, object: nil) }.keyboardShortcut(",")
                Button("关于 AgentBoard…") { NotificationCenter.default.post(name: .boardShowAbout, object: nil) }
                Button("用量统计…") { NotificationCenter.default.post(name: .boardShowStatistics, object: nil) }
                Button("退出 AgentBoard") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18).help("更多选项")
        }.buttonStyle(.plain).foregroundStyle(palette.muted).padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 16)
    }
    private var overview: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("此刻的工作节奏").font(.system(size: 11 * store.preferences.fontScale)).foregroundStyle(palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(store.snapshot.running)").font(.system(size: 36 * store.preferences.fontScale, weight: .medium, design: .rounded)).foregroundStyle(palette.text)
                    Text("个任务执行中").font(.system(size: 12 * store.preferences.fontScale)).foregroundStyle(palette.muted)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Label(store.snapshot.waiting > 0 ? "\(store.snapshot.waiting) 个等待确认" : "暂无待确认", systemImage: store.snapshot.waiting > 0 ? "hand.raised" : "checkmark.circle").font(.system(size: 10 * store.preferences.fontScale, weight: .medium)).foregroundStyle(store.snapshot.waiting > 0 ? .orange : palette.accent)
                HStack(spacing: 4) { Circle().fill(fresh ? palette.accent : .orange).frame(width: 5, height: 5); Text(fresh ? "本机监控已连接" : "等待同步").font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(palette.muted) }
            }
        }.padding(.horizontal, 2).padding(.bottom, 2)
    }
    private var fresh: Bool { Date().timeIntervalSince(store.snapshot.updatedAt) < 30 }
    @ViewBuilder private func module(_ key: String) -> some View {
        switch key { case "usage": usageCard; case "balances": balancesCard; case "tasks": tasksCard; default: EmptyView() }
    }
    private var usageCard: some View {
        BoardCard {
            VStack(alignment: .leading, spacing: 13) {
                cardHeading("今日用量", subtitle: "CC SWITCH", icon: "chart.bar.xaxis")
                Button("查看今日 / 近 7 天 / 本月统计") { NotificationCenter.default.post(name: .boardShowStatistics, object: nil) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.accent)
                HStack(alignment: .firstTextBaseline) {
                    Text(BoardFormat.tokens(store.snapshot.usage.total)).font(.system(size: 29 * store.preferences.fontScale, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("tokens").font(.system(size: 11 * store.preferences.fontScale)).foregroundStyle(palette.muted)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(BoardFormat.money(store.snapshot.usage.cost, unit: "USD")).font(.system(size: 16 * store.preferences.fontScale, weight: .medium, design: .rounded)).foregroundStyle(palette.accent).monospacedDigit()
                        Text("估算费用").font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(palette.muted)
                    }
                }
                GeometryReader { geo in
                    let total = max(1, store.snapshot.usage.total)
                    HStack(spacing: 3) {
                        Capsule().fill(palette.accent).frame(width: max(4, (geo.size.width - 3) * CGFloat(store.snapshot.usage.input) / CGFloat(total)))
                        Capsule().fill(Color(red: 0.55, green: 0.65, blue: 0.95))
                    }
                }.frame(height: 4)
                HStack {
                    metric("输入", value: store.snapshot.usage.input, color: palette.accent)
                    Spacer()
                    metric("输出", value: store.snapshot.usage.output, color: Color(red: 0.55, green: 0.65, blue: 0.95))
                }
                Divider().overlay(.white.opacity(0.04))
                HStack {
                    Text("缓存读取 " + BoardFormat.tokens(store.snapshot.usage.cacheRead))
                    Spacer(minLength: 4)
                    Text("写入 " + BoardFormat.tokens(store.snapshot.usage.cacheWrite))
                }.font(.system(size: 10 * store.preferences.fontScale)).foregroundStyle(palette.muted).lineLimit(1).minimumScaleFactor(0.7)
                if let recordedAt = store.snapshot.usage.latestAt {
                    HStack(spacing: 3) { Text("最新记录"); Text(recordedAt, style: .time); Spacer(minLength: 0); Text("\(store.snapshot.usage.requests) 次请求") }.font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(palette.muted.opacity(0.75))
                }
                if store.snapshot.usageDay != BoardFormat.day() && store.snapshot.usageUpdatedAt != nil { Text("显示上次数据 · " + store.snapshot.usageDay).font(.caption2).foregroundStyle(.orange) }
            }
        }
    }
    private var balancesCard: some View {
        BoardCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack { cardHeading("API 余额", subtitle: "ACCOUNTS", icon: "creditcard"); Spacer(); Button { NotificationCenter.default.post(name: .boardShowAccounts, object: nil) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).foregroundStyle(palette.muted).help("选择展示的 API 账号") }
                if store.selectedAccounts.isEmpty {
                    emptyState("选择你关心的 API", detail: "在设置中勾选账号，余额会自动更新", icon: "plus.circle")
                    Button("选择账号") { NotificationCenter.default.post(name: .boardShowAccounts, object: nil) }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    ForEach(store.selectedAccounts) { account in
                        balanceRow(account)
                        if account.id != store.selectedAccounts.last?.id { Divider().overlay(.white.opacity(0.04)) }
                    }
                }
            }
        }
    }
    private func balanceRow(_ account: APIAccount) -> some View {
        let balance = store.snapshot.balances.first { $0.id == account.id }
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7).fill(palette.accent.opacity(0.10)).frame(width: 30, height: 30).overlay(Image(systemName: "key.horizontal").font(.system(size: 12 * store.preferences.fontScale)).foregroundStyle(palette.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.preferences.name(for: account)).font(.system(size: 12 * store.preferences.fontScale, weight: .medium)).lineLimit(1).help(store.preferences.name(for: account))
                Text(balance?.error ?? (balance?.isManual == true ? "手动余额" : account.appType)).font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(balance?.error == nil ? palette.muted : .orange).lineLimit(2)
            }
            Spacer(minLength: 3)
            VStack(alignment: .trailing, spacing: 4) {
                if let amount = balance?.remaining { Text(BoardFormat.money(amount, unit: balance?.unit ?? "USD")).font(.system(size: 15 * store.preferences.fontScale, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(balance?.error == nil ? palette.text : palette.muted).lineLimit(1).minimumScaleFactor(0.7) }
                else { Text(store.balanceRefreshing ? "查询中" : "—").font(.system(size: 13 * store.preferences.fontScale)).foregroundStyle(palette.muted) }
                if let date = balance?.updatedAt { Text(date, style: .relative).font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(balance?.expired == true ? .orange : palette.muted) }
            }
        }
    }
    private var tasksCard: some View {
        BoardCard {
            VStack(alignment: .leading, spacing: 13) {
                cardHeading("Agent 任务", subtitle: "ACTIVITY", icon: "waveform.path")
                let tasks = store.visibleTasks
                if tasks.isEmpty { emptyState("暂时没有任务", detail: "启用的 agent 开始工作后会出现在这里", icon: "moon.zzz") }
                ForEach(Array(tasks.prefix(showAllTasks ? 60 : 6))) { task in
                    taskRow(task)
                    if task.id != tasks.prefix(showAllTasks ? 60 : 6).last?.id { Divider().overlay(.white.opacity(0.04)) }
                }
                if tasks.count > 6 {
                    Button(showAllTasks ? "收起最近会话" : "显示全部 \(tasks.count) 个会话") { showAllTasks.toggle() }.buttonStyle(.plain).font(.system(size: 10 * store.preferences.fontScale)).foregroundStyle(palette.accent)
                }
                if !store.snapshot.health.isEmpty {
                    Divider().overlay(.white.opacity(0.04))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)], alignment: .leading, spacing: 7) {
                        ForEach(store.snapshot.health) { health in HStack(spacing: 5) { Circle().fill(health.isStale == true ? .orange : (health.available ? palette.accent : palette.muted.opacity(0.5))).frame(width: 4, height: 4); Text(health.agent.title).lineLimit(1); if health.isStale == true { Text("重试中").foregroundStyle(.orange) } else if !health.available { Text("未连接").foregroundStyle(palette.muted.opacity(0.6)) } }.font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(palette.muted).help(health.message) }
                    }
                    ForEach(store.snapshot.health.filter { !$0.available || $0.isStale == true }) { health in
                        HStack(alignment: .top) {
                            Text(health.agent.title + "：" + health.message).font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("重试") { store.refresh(force: true) }.buttonStyle(.plain).font(.system(size: 9)).disabled(store.refreshing)
                        }
                    }
                }
            }
        }
    }
    private func taskRow(_ task: AgentTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.agent.symbol).font(.system(size: 13 * store.preferences.fontScale)).foregroundStyle(palette.color(task.state)).frame(width: 24, height: 26).background(palette.color(task.state).opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(task.agent.title).font(.system(size: 10 * store.preferences.fontScale, weight: .semibold)).foregroundStyle(palette.muted).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(task.state.title).font(.system(size: 9 * store.preferences.fontScale, weight: .medium)).foregroundStyle(palette.color(task.state)).lineLimit(1)
                }
                Text(task.title).font(.system(size: 12 * store.preferences.fontScale, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let tokens = task.sessionTokens { Text("会话累计 " + BoardFormat.tokens(tokens) + " tokens").font(.system(size: 9)).foregroundStyle(palette.muted) }
                if let usage = task.requestUsage { Text("CC 记录：" + BoardFormat.tokens(usage.total) + " tokens · " + BoardFormat.money(usage.cost, unit: "USD")).font(.system(size: 9)).foregroundStyle(palette.accent).help("按会话 ID 准确匹配的 CC Switch 明细，仅覆盖本月及近 7 天，不代表当前轮次的全部用量。") }
                Button(AgentNavigation.sessionURL(task) != nil ? "打开会话 ↗" : "定位数据 ↗") { AgentNavigation.open(task) }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(palette.accent)
                HStack(spacing: 4) {
                    if !task.project.isEmpty { Image(systemName: "folder"); Text((task.project as NSString).lastPathComponent).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(task.updatedAt, style: .relative).lineLimit(1)
                }.font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(palette.muted)
            }
        }
        .help(task.source + (task.detail.isEmpty ? "" : "\n" + task.detail))
        .contextMenu {
            Text(task.source)
            if !task.detail.isEmpty { Text(task.detail) }
            if let path = task.sourcePath { Button("在访达中显示数据文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            if task.project.hasPrefix("/") { Button("打开项目文件夹") { NSWorkspace.shared.open(URL(fileURLWithPath: task.project)) } }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
            Image(systemName: "lock.shield")
            Text("本地读取 · 缓存 token 单独列示")
            Spacer(minLength: 2)
            if let date = store.snapshot.usageUpdatedAt { Text(date, style: .time) }
            }
            Text("v" + BoardIdentity.version + " · " + BoardIdentity.copyright).font(.system(size: 8 * store.preferences.fontScale)).lineLimit(1).minimumScaleFactor(0.7)
        }.font(.system(size: 9 * store.preferences.fontScale)).foregroundStyle(palette.muted.opacity(0.65)).padding(.horizontal, 2)
    }
    private func cardHeading(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon).foregroundStyle(palette.muted); Text(title).foregroundStyle(palette.text.opacity(0.92)); Spacer(minLength: 4); Text(subtitle).font(.system(size: 8 * store.preferences.fontScale, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(palette.muted.opacity(0.6)) }.font(.system(size: 11 * store.preferences.fontScale, weight: .medium))
    }
    private func metric(_ title: String, value: Int64, color: Color) -> some View { HStack(spacing: 5) { Circle().fill(color).frame(width: 4, height: 4); Text(title).foregroundStyle(palette.muted); Text(BoardFormat.tokens(value)).foregroundStyle(palette.text) }.font(.system(size: 10 * store.preferences.fontScale)).monospacedDigit() }
    private func emptyState(_ title: String, detail: String, icon: String) -> some View { VStack(alignment: .leading, spacing: 7) { Label(title, systemImage: icon).font(.system(size: 12 * store.preferences.fontScale, weight: .medium)); Text(detail).font(.system(size: 10 * store.preferences.fontScale)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true) }.padding(.vertical, 6) }
}

extension Notification.Name {
    static let boardShowPanel = Notification.Name("AgentBoard.showPanel")
    static let boardHidePanel = Notification.Name("AgentBoard.hidePanel")
    static let boardShowSettings = Notification.Name("AgentBoard.showSettings")
    static let boardShowAccounts = Notification.Name("AgentBoard.showAccounts")
    static let boardSelectAccountsTab = Notification.Name("AgentBoard.selectAccountsTab")
    static let boardShowStatistics = Notification.Name("AgentBoard.showStatistics")
    static let boardSelectStatisticsTab = Notification.Name("AgentBoard.selectStatisticsTab")
    static let boardShowAbout = Notification.Name("AgentBoard.showAbout")
}
