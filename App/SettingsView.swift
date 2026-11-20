import SwiftUI
import ServiceManagement

struct BoardSettingsView: View {
    @EnvironmentObject var store: BoardStore
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    @State var selectedTab = 0
    @State private var editor: ManualAccount?
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(spacing: 14) {
            Picker("设置页面", selection: $selectedTab) {
                Label("展示", systemImage: "macwindow").tag(0)
                Label("API 账号", systemImage: "key.horizontal").tag(1)
                Label("Agents", systemImage: "cpu").tag(2)
                Label("连接状态", systemImage: "waveform.path.ecg").tag(3)
                Label("统计", systemImage: "chart.bar.xaxis").tag(4)
                Label("提醒", systemImage: "bell").tag(5)
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch selectedTab { case 0: appearance; case 1: accounts; case 2: agents; case 3: diagnostics; case 4: StatisticsView().environmentObject(store); default: AlertSettingsView().environmentObject(store) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = store.notice { HStack { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled); Spacer(); Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) } }
            VStack(spacing: 3) {
                Text(BoardIdentity.author).font(.system(size: 12, weight: .semibold))
                Text(BoardIdentity.title + "（构建 " + BoardIdentity.build + "） · " + BoardIdentity.copyright).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(20).frame(minWidth: 640, minHeight: 550)
        .background(palette.background).foregroundStyle(palette.text).preferredColorScheme(palette.isLight ? .light : .dark).tint(palette.accent)
        .onReceive(NotificationCenter.default.publisher(for: .boardSelectAccountsTab)) { _ in selectedTab = 1 }
        .sheet(item: $editor) { account in AccountEditor(account: account).environmentObject(store) }
        .sheet(isPresented: $store.showOnboarding) { OnboardingView().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .boardSelectStatisticsTab)) { _ in selectedTab = 4 }
    }
    private func binding<T>(_ path: WritableKeyPath<BoardPreferences, T>) -> Binding<T> { Binding(get: { store.preferences[keyPath: path] }, set: { store.preferences[keyPath: path] = $0; store.save() }) }
    private func miniBinding<T>(_ path: WritableKeyPath<MiniPreferences, T>) -> Binding<T> { Binding(get: { store.preferences.miniOptions[keyPath: path] }, set: { var mini = store.preferences.miniOptions; mini[keyPath: path] = $0; store.preferences.miniOptions = mini; store.save() }) }
    private var appearance: some View {
        Form {
            Section("主题颜色") { ThemeEditor().environmentObject(store) }
            Section("菜单栏与浮窗") {
                Picker("菜单栏显示", selection: binding(\.menuMetric)) { Text("运行任务数").tag("tasks"); Text("今日 token").tag("tokens"); Text("第一个所选账号余额").tag("balance"); Text("仅图标").tag("icon") }
                Toggle("显示常驻浮窗", isOn: binding(\.floatVisible))
                Toggle("浮窗置顶", isOn: binding(\.pinned))
                Toggle("在所有桌面显示", isOn: binding(\.allSpaces))
                Toggle("迷你模式（悬停展开详情）", isOn: binding(\.compact))
                LabeledContent("背景不透明度") { Slider(value: binding(\.opacity), in: 0.65...1).frame(width: 190); Text("\(Int(store.preferences.opacity * 100))%").monospacedDigit().frame(width: 42) }
                LabeledContent("文字大小") { Slider(value: binding(\.fontScale), in: 0.85...1.3, step: 0.05).frame(width: 190); Text("\(Int(store.preferences.fontScale * 100))%").monospacedDigit().frame(width: 42) }
            }
            Section("迷你圆环") {
                Picker("显示内容", selection: miniBinding(\.metric)) { ForEach(MiniMetric.allCases) { Text($0.title).tag($0) } }
                Picker("外形", selection: miniBinding(\.shape)) { ForEach(MiniShape.allCases) { Text($0.title).tag($0) } }
                Picker("圆环直径", selection: miniBinding(\.diameter)) { Text("40 点 · 极小").tag(40.0); Text("48 点 · 默认").tag(48.0); Text("56 点 · 清晰").tag(56.0) }
                Picker("余额账号", selection: miniBinding(\.accountID)) {
                    Text("第一个所选账号").tag(String?.none)
                    ForEach(store.selectedAccounts) { account in Text(store.preferences.name(for: account)).tag(Optional(account.id)) }
                }
                Toggle("状态变化时轻微动画", isOn: Binding(get: { store.preferences.miniOptions.animations ?? true }, set: { store.preferences.miniOptions.animations = $0; store.save() }))
                Toggle("自动轮播多个指标", isOn: Binding(get: { (store.preferences.miniOptions.rotation ?? []).count > 1 }, set: { store.preferences.miniOptions.rotation = $0 ? [.tasks, .tokens, .costAndBalance] : []; store.save() }))
                if !(store.preferences.miniOptions.rotation ?? []).isEmpty {
                    ForEach(MiniMetric.allCases) { metric in Toggle(metric.title, isOn: Binding(get: { store.preferences.miniOptions.rotation?.contains(metric) == true }, set: { enabled in var values = store.preferences.miniOptions.rotation ?? []; if enabled { if !values.contains(metric) { values.append(metric) } } else { values.removeAll { $0 == metric } }; store.preferences.miniOptions.rotation = values; store.save() })).toggleStyle(.checkbox) }
                    Picker("轮播间隔", selection: Binding(get: { store.preferences.miniOptions.rotationInterval ?? 6 }, set: { store.preferences.miniOptions.rotationInterval = $0; store.save() })) { Text("3 秒").tag(3.0); Text("6 秒").tag(6.0); Text("10 秒").tag(10.0); Text("30 秒").tag(30.0) }
                    Text("选择至少两项时自动轮播；静态模式保持你选择的显示内容。").font(.caption).foregroundStyle(.secondary)
                }
                Text("平时仅显示小圆环；悬停显示任务、用量和余额，移开后收起。拖动可移动，双击展开完整浮窗，右键快速切换指标。圆环边框颜色表示状态，不代表已用额度比例。").font(.caption).foregroundStyle(.secondary)
            }
            Section("模块顺序与显隐") {
                ForEach(Array(store.preferences.moduleOrder.enumerated()), id: \.element) { index, module in
                    HStack {
                        Toggle(["usage": "今日用量", "balances": "API 余额", "tasks": "Agent 任务"][module] ?? module, isOn: Binding(get: { !store.preferences.hiddenModules.contains(module) }, set: { enabled in if enabled { store.preferences.hiddenModules.removeAll { $0 == module } } else { store.preferences.hiddenModules.append(module) }; store.save() }))
                        Spacer()
                        Button { store.preferences.moduleOrder.swapAt(index, index - 1); store.save() } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { store.preferences.moduleOrder.swapAt(index, index + 1); store.save() } label: { Image(systemName: "chevron.down") }.disabled(index == store.preferences.moduleOrder.count - 1)
                    }
                }
            }
            Section("系统") {
                HStack { ForEach(BoardPreset.allCases) { preset in Button(preset.title) { preset.apply(to: &store.preferences); store.save() } } }
                HStack { Button("设置向导") { store.showOnboarding = true }; Button("导出配置") { store.exportConfiguration() }; Button("导入配置") { store.importConfiguration() }; Button("恢复导入前配置") { store.restoreConfigurationBackup() } }
                Text("配置迁移不包含密钥、API 接口或本机路径；导入前自动备份当前配置。").font(.caption).foregroundStyle(.secondary)
                Toggle("登录后启动", isOn: Binding(get: { loginEnabled }, set: { enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
                    catch { store.notice = "登录启动设置失败：" + error.localizedDescription; loginEnabled = false }
                }))
                Text("桌面右键 → 编辑小组件 → 搜索 AgentBoard。小组件支持小、中、大尺寸，可分别选择主题和账号；更新时间由系统调度。").font(.caption).foregroundStyle(.secondary)
                if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped)
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("选择展示的 API").font(.title3.bold()); Text("勾选后同步到浮窗和小组件；别名可直接修改。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("添加账号", systemImage: "plus") { editor = ManualAccount() }; Button { store.refresh(force: true); store.refreshBalances() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.balanceRefreshing) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.accounts) { account in
                        BoardCard {
                            HStack(alignment: .top, spacing: 12) {
                                Toggle("", isOn: Binding(get: { store.preferences.selectedAccounts.contains(account.id) }, set: { store.toggleAccount(account.id, enabled: $0) })).labelsHidden().toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { TextField(account.name, text: Binding(get: { store.preferences.accountAliases[account.id] ?? "" }, set: { store.preferences.accountAliases[account.id] = $0; store.save() })).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)); if account.current { Text("当前").font(.caption2).foregroundStyle(palette.accent) } }
                                    Text(account.appType + " · " + balanceLabel(account.balanceKind)).font(.caption).foregroundStyle(.secondary)
                                    if let balance = store.snapshot.balances.first(where: { $0.id == account.id }) {
                                        if let amount = balance.remaining { Text(BoardFormat.money(amount, unit: balance.unit)).font(.system(.body, design: .rounded)).foregroundStyle(palette.accent) }
                                        if let error = balance.error { Text(error).font(.caption).foregroundStyle(.orange) }
                                    }
                                    if account.usage.requests > 0 { Text("今日 " + BoardFormat.tokens(account.usage.total) + " tokens · " + BoardFormat.money(account.usage.cost, unit: "USD") + " 估算").font(.caption2).foregroundStyle(.secondary) }
                                }
                                if account.appType == "自定义", let custom = store.preferences.manualAccounts.first(where: { "manual:" + $0.id == account.id }) {
                                    Button("编辑") { editor = custom }.controlSize(.small)
                                    Button(role: .destructive) {
                                        do { try KeychainStore.write("", id: custom.id); store.preferences.manualAccounts.removeAll { $0.id == custom.id }; store.preferences.selectedAccounts.removeAll { $0 == account.id }; store.save() } catch { store.notice = error.localizedDescription }
                                    } label: { Image(systemName: "trash") }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            Text("自动查询支持 CC Switch 的 sub2api 模板及 DeepSeek 官方余额接口。其他供应商可添加 HTTPS JSON 查询或手动余额；不同币种分别展示。").font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 14)
    }
    private var agents: some View {
        Form {
            Section("自动检测") {
                HStack { Button("检测已安装的 Agent") { store.detectAgents() }; Button("打开设置向导") { store.showOnboarding = true } }
                Text(store.detectedAgents.isEmpty ? "点击检测，根据本机数据目录识别工具。" : "已发现：" + store.detectedAgents.map(\.title).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
            }
            Section("监控对象") {
                ForEach(AgentKind.allCases) { agent in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(agent.title, isOn: Binding(get: { store.preferences.enabledAgents.contains(agent.rawValue) }, set: { enabled in
                            if enabled { store.preferences.enabledAgents.append(agent.rawValue) } else { store.preferences.enabledAgents.removeAll { $0 == agent.rawValue } }
                            store.save(); store.refresh(force: true)
                        }))
                        TextField("数据目录", text: Binding(get: { store.preferences.agentPaths[agent.rawValue] ?? agent.defaultPath }, set: { store.preferences.agentPaths[agent.rawValue] = $0; store.save() })).font(.system(.caption, design: .monospaced))
                        if let health = store.snapshot.health.first(where: { $0.agent == agent }) { Text(health.message).font(.caption2).foregroundStyle(health.available ? Color.secondary : Color.orange) }
                    }.padding(.vertical, 3)
                }
            }
            Section("任务展示") {
                Toggle("展示最近完成和中断的会话", isOn: binding(\.showRecentCompleted))
                Text("Codex、WorkBuddy、Harness 读取本机会话。Qwen 和 Claude 的会话格式不保证提供结束状态；可使用 AgentBoard 事件文件获得准确状态。超过 10 分钟未更新的运行状态会标记为待确认。").font(.caption).foregroundStyle(.secondary)
                Button("打开事件接入目录") {
                    let path = SharedStorage.localDirectory.appendingPathComponent("events")
                    try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(path)
                }
            }
        }.formStyle(.grouped)
    }
    private var diagnostics: some View {
        Form {
            Section("刷新频率") {
                Picker("任务状态", selection: binding(\.taskInterval)) { Text("3 秒").tag(3.0); Text("5 秒").tag(5.0); Text("10 秒").tag(10.0) }
                Picker("用量", selection: binding(\.usageInterval)) { Text("15 秒").tag(15.0); Text("30 秒").tag(30.0); Text("60 秒").tag(60.0) }
                Picker("余额", selection: binding(\.balanceInterval)) { Text("5 分钟").tag(300.0); Text("10 分钟").tag(600.0); Text("30 分钟").tag(1800.0) }
            }
            Section("数据连接") {
                TextField("CC Switch 数据库", text: binding(\.ccPath))
                ForEach(store.snapshot.health) { health in
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent(health.agent.title) { Text((health.category?.title ?? (health.available ? "已连接" : "读取失败")) + " · " + health.message).foregroundStyle(health.available && health.isStale != true ? Color.secondary : Color.orange).textSelection(.enabled) }
                        HStack { if let date = health.lastSuccessAt { Text("最近成功 " + date.formatted(date: .omitted, time: .standard)) } else { Text("尚无成功读取记录") }; Spacer(); if let date = health.checkedAt { Text("检测于 " + date.formatted(date: .omitted, time: .standard)) } }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(store.snapshot.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                if let date = store.snapshot.usageUpdatedAt { LabeledContent("用量更新时间", value: date.formatted()) }
                LabeledContent("小组件共享目录") { Text(SharedStorage.directory.path).font(.caption2).textSelection(.enabled) }
                HStack { Button("立即重新检测") { store.refresh(force: true); store.refreshBalances() }; Button("导出脱敏诊断") { store.exportDiagnostics() } }
                Text("诊断文件仅含版本、连接分类、时间和数量，不含任务正文、路径、账号名称或密钥。").font(.caption).foregroundStyle(.secondary)
            }
            Section("数据口径") {
                Text("用量来自 CC Switch 当前数据库，只代表已被它记录的请求。输入与输出相加展示为 token 总量，缓存另列；不同来源是否已去重取决于 CC Switch。费用为估算值，余额以供应商查询结果为准。").font(.caption).foregroundStyle(.secondary)
                Text("小组件读取不含密钥的本地快照。API 密钥仅从现有配置即时读取，手动添加的密钥保存到 macOS 钥匙串。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func balanceLabel(_ kind: String) -> String { ["sub2api": "自动余额查询", "deepseek": "官方余额接口", "custom": "自定义余额接口", "manual": "手动余额", "unsupported": "需配置余额查询"][kind] ?? kind }
}

struct AccountEditor: View {
    @EnvironmentObject var store: BoardStore
    private var palette: BoardPalette { BoardPalette(store.preferences.themeOptions) }
    @Environment(\.dismiss) var dismiss
    @State var account: ManualAccount
    @State private var key = ""
    @State private var manual = false
    @State private var amount = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("API 余额账号").font(.title2.bold())
            Form {
                TextField("账号名称", text: $account.name)
                Toggle("手动维护余额", isOn: $manual)
                if manual { TextField("剩余金额", text: $amount) }
                else {
                    TextField("HTTPS 查询地址", text: $account.endpoint, prompt: Text("https://api.example.com/balance"))
                    SecureField("API Key（Bearer，可留空）", text: $key)
                    TextField("余额 JSON 字段", text: $account.amountPath, prompt: Text("data.balance"))
                    Text("仅发送 GET 请求；字段支持 data.balance 或 balance_infos.0.total_balance。已有密钥留空可保留。").font(.caption).foregroundStyle(.secondary)
                }
                TextField("币种／单位", text: $account.unit)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(26).frame(width: 510).foregroundStyle(palette.text).tint(palette.accent).background(palette.background).preferredColorScheme(palette.isLight ? .light : .dark)
        .onAppear { manual = account.staticAmount != nil; amount = account.staticAmount.map { String($0) } ?? "" }
    }
    private func save() {
        guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "请填写账号名称"; return }
        if manual {
            guard let value = Double(amount), value.isFinite else { error = "请输入有效金额"; return }; account.staticAmount = value
        } else {
            guard let url = URL(string: account.endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { error = "请输入有效的 HTTPS 地址"; return }
            guard !account.amountPath.isEmpty else { error = "请填写余额字段路径"; return }; account.staticAmount = nil
        }
        do {
            if !key.isEmpty { try KeychainStore.write(key, id: account.id) }
            if let i = store.preferences.manualAccounts.firstIndex(where: { $0.id == account.id }) { store.preferences.manualAccounts[i] = account }
            else { store.preferences.manualAccounts.append(account) }
            if !store.preferences.selectedAccounts.contains("manual:" + account.id) { store.preferences.selectedAccounts.append("manual:" + account.id) }
            store.save(); store.refreshBalances(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
