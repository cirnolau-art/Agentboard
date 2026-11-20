import Foundation
import SQLite3

@MainActor enum FeatureTests {
    static func run(root: URL, check: (Bool, String) -> Void) throws {
        let defaults = BoardPreferences()
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        for key in ["theme", "alerts", "usagePeriod", "onboardingCompleted"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(BoardPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.themeOptions.valid && !decoded.alertOptions.enabled && decoded.enabledAgents == defaults.enabledAgents, "v0.2 设置无损迁移，通知默认关闭")
        check(ThemeSettings.presets.allSatisfy { $0.1.valid } && BoardPalette(ThemeSettings.presets[4].1).isLight, "全部预设主题有效且纸白主题使用浅色控件")
        check(ThemeSettings.normalizedHex(" #aAbB12 ") == "AABB12" && ThemeSettings.normalizedHex("GG0000") == nil && ThemeSettings.normalizedHex("fff") == nil, "自定义 HEX 规范化并拒绝非法颜色")
        var invalidTheme = ThemeSettings(); invalidTheme.accent = "broken"
        check(BoardPalette(invalidTheme).theme == ThemeSettings(), "损坏的主题回退默认配色")
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        func seconds(_ days: Int) -> Int { Int(Calendar.current.date(byAdding: .day, value: days, to: today)!.addingTimeInterval(10).timeIntervalSince1970) }
        let database = root.appendingPathComponent("analytics.sqlite")
        var db: OpaquePointer?; sqlite3_open(database.path, &db); defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE proxy_request_logs (app_type TEXT,provider_id TEXT,model TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_creation_tokens INT,total_cost_usd TEXT,created_at INT,session_id TEXT);
        INSERT INTO proxy_request_logs VALUES ('codex','a','model-a',100,20,50,0,'0.12',\(seconds(0)),'exact');
        INSERT INTO proxy_request_logs VALUES ('dsh','a','model-b',30,4,0,0,'0.02',\(seconds(0)),'other');
        INSERT INTO proxy_request_logs VALUES ('codex','a','model-a',5,2,0,0,'0.01',\(seconds(-1)),NULL);
        INSERT INTO proxy_request_logs VALUES ('codex','a','model-a',10,1,0,0,'0.03',\(seconds(-6)),NULL);
        INSERT INTO proxy_request_logs VALUES ('codex','a','model-a',90,3,0,0,'0.9',\(seconds(-7)),NULL);
        INSERT INTO proxy_request_logs VALUES ('codex','a',NULL,2,0,0,0,'0',\(seconds(0)),NULL);
        INSERT INTO proxy_request_logs VALUES ('codex','a','',3,0,0,0,'0',\(seconds(0)),NULL);
        INSERT INTO proxy_request_logs VALUES ('codex','a','future',999,999,0,0,'99',\(seconds(1)),NULL);
        CREATE TABLE usage_daily_rollups (date TEXT,app_type TEXT,provider_id TEXT,model TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_creation_tokens INT,total_cost_usd TEXT,request_count INT);
        INSERT INTO usage_daily_rollups VALUES ('\(BoardFormat.day(now))','codex','a','model-a',100,20,50,0,'0.12',1);
        INSERT INTO usage_daily_rollups VALUES ('\(BoardFormat.day(Calendar.current.date(byAdding: .day,value: -1,to: today)!))','codex','a','model-c',8,2,0,0,'0.04',2);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ReaderError.message("统计测试数据库创建失败") }
        let stats = try UsageAnalytics.read(path: database.path, now: now)
        check(stats.total(for: .today, now: now).total == 159, "今日统计排除昨天和未来，并合并缺失模型")
        check(abs(stats.total(for: .today, now: now).cost - 0.14) < 0.000001, "日／API／模型去重，明细与汇总不重复相加")
        check(stats.total(for: .week, now: now).total == 187, "近 7 天包含第六天并排除第七天之前数据")
        let monthExpected: Int64 = BoardFormat.day(Calendar.current.date(byAdding: .day,value: -7,to: today)!) >= BoardFormat.day(UsagePeriod.month.start(now: now)) ? 280 : 187
        check(stats.total(for: .month, now: now).total == monthExpected, "本月以本机月初为边界")
        check(stats.buckets.contains { $0.accountID == "codex:a" } && stats.buckets.contains { $0.accountID == "dsh:a" }, "同一 provider ID 按 API 工具独立分组")
        check(stats.buckets.filter { $0.model == "未记录模型" }.reduce(Int64(0)) { $0 + $1.usage.total } == 5, "空字符串与 NULL 模型合并而不丢失数据")
        check(stats.sessionUsage["codex:exact"]?.total == 120 && stats.sessionUsage["codex:other"] == nil, "仅按完整工具与会话 ID 匹配请求用量")
        var local = BoardPreferences(); local.ccPath = "/private/local.db"; local.agentPaths = ["codex": "/local/codex"]
        local.manualAccounts = [ManualAccount(id: "one", name: "Private", endpoint: "https://example.com/?key=sk-secret")]
        local.selectedAccounts = ["known"]; local.alertOptions.enabled = false
        var imported = local; imported.themeOptions = ThemeSettings.presets[2].1; imported.selectedAccounts = ["known", "missing"]; imported.alertOptions.enabled = true
        let document = ConfigurationDocument(imported)
        let portable = String(data: try JSONEncoder().encode(document), encoding: .utf8)!
        check(!portable.contains("sk-secret") && !portable.contains("/private/local.db") && !portable.contains("/local/codex"), "配置导出不包含接口凭据和本机路径")
        let restored = try JSONDecoder().decode(ConfigurationDocument.self, from: Data(portable.utf8)).applying(to: local, knownAccounts: ["known"])
        check(restored.themeOptions == imported.themeOptions && restored.manualAccounts == local.manualAccounts && restored.agentPaths == local.agentPaths && restored.ccPath == local.ccPath, "配置导入应用主题并保留本机接口、路径和账号")
        check(restored.selectedAccounts == ["known"] && !restored.alertOptions.enabled, "配置导入过滤不存在的账号且不替换本机通知授权")
        var bad = document; bad.preferences.themeOptions.accent = "invalid"
        check((try? bad.applying(to: local, knownAccounts: [])) == nil, "非法导入配置不会覆盖现有设置")
        var preset = local; BoardPreset.focus.apply(to: &preset)
        check(preset.moduleOrder.first == "tasks" && !preset.showRecentCompleted && preset.selectedAccounts == local.selectedAccounts && preset.manualAccounts == local.manualAccounts, "专注预设调整展示且不改动账号数据")
        var reportSnapshot = BoardSnapshot.empty
        reportSnapshot.health = [AgentHealth(agent: .codex, available: false, message: "sk-private /Users/private", category: .unreadable)]
        reportSnapshot.tasks = [AgentTask(id: "secret-id", agent: .codex, title: "secret-title", project: "/private/project", state: .failed, updatedAt: now, source: "secret-source")]
        reportSnapshot.issues = ["sk-private"]
        let report = String(data: try JSONEncoder().encode(SanitizedDiagnostics(snapshot: reportSnapshot)), encoding: .utf8)!
        check(!report.contains("sk-private") && !report.contains("secret-title") && !report.contains("/private") && !report.contains("secret-id"), "诊断导出严格白名单，不泄露标题、路径、凭据或会话 ID")
        let readers = AgentReaders(now: { now })
        let health = readers.read(.codex, path: root.appendingPathComponent("codex").path).health
        check(health.checkedAt == now && health.lastSuccessAt == now && health.category == .connected, "连接诊断记录检测时间和成功时间")
        let missing = readers.read(.qwen, path: root.appendingPathComponent("absent").path).health
        check(missing.category == .notInstalled && missing.lastSuccessAt == nil, "未发现工具目录与读取错误分类区分")
        var detection = BoardPreferences(); detection.agentPaths = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0.rawValue, root.appendingPathComponent("missing-" + $0.rawValue).path) }); detection.agentPaths["codex"] = root.appendingPathComponent("codex").path
        check(AgentDetection.installed(detection) == [.codex], "自动检测仅选择发现真实数据的 Agent")
        var task = reportSnapshot.tasks[0]; task.id = "codex:00000000-0000-0000-0000-000000000001"
        check(AgentNavigation.sessionURL(task)?.absoluteString == "codex://threads/00000000-0000-0000-0000-000000000001", "Codex 跳转使用对应会话 ID")
        task.id = "codex:invalid/../path"; check(AgentNavigation.sessionURL(task) == nil, "不可信会话 ID 不生成跳转链接")
        let rotationStore = BoardStore(); rotationStore.preferences = BoardPreferences(); rotationStore.preferences.compact = true
        rotationStore.preferences.miniOptions.rotation = [.tasks, .tokens, .balance]; rotationStore.preferences.miniOptions.rotationInterval = 3
        rotationStore.rotateMiniIfNeeded(now: now.addingTimeInterval(10))
        check(rotationStore.miniDisplayMetric == .tokens && rotationStore.preferences.miniOptions.metric == .tasks, "轮播切换显示值且不覆盖手动选项")
        rotationStore.miniDetailOpen = true; rotationStore.rotateMiniIfNeeded(now: now.addingTimeInterval(20))
        check(rotationStore.miniDisplayMetric == .tokens, "鼠标查看详情时暂停指标轮播")
        var alerts = AlertEvaluator(); var p = BoardPreferences(); p.selectedAccounts = ["api"]; p.alertOptions.enabled = true
        let account = APIAccount(id: "api", providerID: "p", appType: "codex", name: "Test API", balanceKind: "manual", current: true)
        var s = BoardSnapshot.empty
        var t = AgentTask(id: "task", agent: .codex, title: "Fixture", project: "", state: .running, updatedAt: now, startedAt: now.addingTimeInterval(-20), source: "fixture")
        s.tasks = [t]
        check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "通知首次采集不补发历史任务")
        t.state = .waiting; s.tasks = [t]
        check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).count == 1, "进入等待确认时发送一次提醒")
        check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "持续等待不会重复提醒")
        t.state = .running; s.tasks = [t]; _ = alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now)
        t.state = .waiting; s.tasks = [t]; check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "同一轮次再次等待仍按状态去重")
        t.state = .completed; s.tasks = [t]; check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).count == 1, "任务完成发送一次提醒")
        var restarted = AlertEvaluator(); restarted.ledger = try JSONDecoder().decode(AlertLedger.self, from: JSONEncoder().encode(alerts.ledger))
        check(restarted.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "通知记录持久化后重启不重发已完成任务")
        p.alertOptions.quietEnabled = true; p.alertOptions.quietStart = 0; p.alertOptions.quietEnd = 0
        t.state = .failed; s.tasks = [t]; check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "全天静音期间不发送失败提醒")
        p.alertOptions.quietEnabled = false; check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "静音结束不集中补发历史状态")
        p.alertOptions.thresholds["api"] = BalanceThreshold(amount: 5, unit: "USD")
        s.balances = [Balance(id: "api", remaining: 3, updatedAt: now)]
        check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).count == 1, "跌破 API 余额阈值发送提醒")
        check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "余额持续偏低不重复提醒")
        s.balances[0].remaining = 9; _ = alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now)
        s.balances[0].remaining = 2; check(alerts.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).count == 1, "余额回升后再跌破重新提醒")
        var foreign = AlertEvaluator(); s.balances[0].unit = "CNY"
        check(foreign.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "不同币种不错误比较阈值")
        s.balances[0].unit = "USD"; s.balances[0].error = "Failed"
        check(foreign.evaluate(snapshot: s, preferences: p, accounts: [account], now: now).isEmpty, "余额查询失败不使用旧值发出低余额警报")
        var quiet = AlertPreferences(); quiet.quietEnabled = true; quiet.quietStart = 22; quiet.quietEnd = 8
        let night = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now)!, noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        check(quiet.isQuiet(at: night) && !quiet.isQuiet(at: noon), "跨午夜静音时段边界正确")
    }
}
