import AppKit
import SwiftUI
import WidgetKit
import SQLite3

enum Diagnostics {
    static func run() {
        Task { @MainActor in
            let prefs = SharedStorage.read(BoardPreferences.self, name: "preferences.json", directory: SharedStorage.localDirectory) ?? BoardPreferences()
            let snapshot = await MonitorEngine().poll(prefs, force: true)
            let result: [String: Any] = ["version": BoardIdentity.version, "build": BoardIdentity.build, "author": BoardIdentity.author, "accountCount": snapshot.accounts.count, "todayTokens": snapshot.usage.total, "requestCount": snapshot.usage.requests, "tasks": snapshot.tasks.count, "running": snapshot.running, "health": snapshot.health.map { ["agent": $0.agent.rawValue, "connected": $0.available, "retrying": $0.isStale == true, "message": $0.message] as [String: Any] }, "issues": snapshot.issues, "sharedDirectory": SharedStorage.directory.path]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            if CommandLine.arguments.contains("--check-balances") {
                let records = (try? CCReader.providers(path: prefs.ccPath)) ?? []
                let service = BalanceService()
                for record in records where record.account.balanceKind != "unsupported" {
                    let balance = await service.query(record, custom: nil, previous: nil)
                    print("BALANCE", record.account.appType, balance.remaining.map { BoardFormat.money($0, unit: balance.unit) } ?? "未知", balance.error ?? "OK")
                }
            }
            exit(snapshot.issues.isEmpty ? 0 : 1)
        }
    }
}

enum SelfTests {
    static func run() {
        Task { @MainActor in
            var failures: [String] = []; var passed = 0
            func check(_ condition: @autoclosure () -> Bool, _ name: String) { if condition() { passed += 1; print("PASS " + name) } else { failures.append(name); print("FAIL " + name) } }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-test-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                func database(_ name: String, sql: String) throws -> String {
                    let path = root.appendingPathComponent(name).path
                    var db: OpaquePointer?; sqlite3_open(path, &db); defer { sqlite3_close(db) }
                    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ReaderError.message("测试数据库构建失败") }
                    return path
                }
                let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
                let path = try database("cc.db", sql: """
                CREATE TABLE providers (id TEXT,app_type TEXT,name TEXT,settings_config TEXT,meta TEXT,is_current INT,sort_index INT);
                INSERT INTO providers VALUES ('a','codex','Test','{}','{}',1,0);
                INSERT INTO providers VALUES ('a','dsh','Test DSH','{}','{}',1,1);
                CREATE TABLE proxy_request_logs (app_type TEXT,provider_id TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_creation_tokens INT,total_cost_usd TEXT,created_at INT);
                INSERT INTO proxy_request_logs VALUES ('codex','a',100,20,50,10,'0.12',\(start + 5));
                INSERT INTO proxy_request_logs VALUES ('dsh','a',30,4,0,0,'0.02',\(start + 10));
                INSERT INTO proxy_request_logs VALUES ('codex','a',999,999,0,0,'99',\(start - 1));
                CREATE TABLE usage_daily_rollups (date TEXT,app_type TEXT,provider_id TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_creation_tokens INT,total_cost_usd TEXT,request_count INT);
                INSERT INTO usage_daily_rollups VALUES ('\(BoardFormat.day())','codex','a',100,20,50,10,'0.12',1);
                """)
                let records = try CCReader.providers(path: path)
                check(Set(records.map { $0.account.id }).count == 2, "相同 provider ID 按工具区分")
                let (usage, accounts) = try CCReader.usage(path: path, accounts: records.map(\.account))
                check(usage.input == 130 && usage.output == 24, "今日边界排除昨天数据")
                check(usage.total == 154 && usage.cacheRead == 50, "缓存与输入输出分别统计")
                check(abs(usage.cost - 0.14) < 0.00001, "raw 与 rollup 重叠不重复累加")
                check(accounts.first { $0.appType == "dsh" }?.usage.total == 34, "账号用量独立归属")
                let readers = AgentReaders()
                check(readers.normalized("inProgress") == .running, "Codex inProgress 状态")
                check(readers.normalized("requires_action") == .waiting, "等待确认状态")
                check(readers.normalized("something-new") == .unknown, "新状态不会被误判为完成")
                let events = root.appendingPathComponent("events"); try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
                let event: [String: Any] = ["schema": "agentboard.v1", "taskId": "one", "agent": "qwen", "title": "Test task", "state": "completed", "updatedAt": Date().timeIntervalSince1970]
                let event2: [String: Any] = ["schema": "agentboard.v1", "taskId": "stale", "agent": "qwen", "state": "running", "updatedAt": Date().addingTimeInterval(-1200).timeIntervalSince1970]
                var eventData = try JSONSerialization.data(withJSONObject: event); eventData.append(0x0A); eventData.append(try JSONSerialization.data(withJSONObject: event2)); try eventData.write(to: events.appendingPathComponent("events.jsonl"))
                let read = readers.read(.qwen, path: events.path)
                check(read.tasks.count == 2, "事件接入解析多个任务")
                check(read.tasks.first { $0.id == "qwen:one" }?.state == .completed, "明确结束事件标记完成")
                check(read.tasks.first { $0.id == "qwen:stale" }?.state == .unknown, "陈旧运行事件标记未知")
                check(!readers.read(.qwen, path: root.path + "/missing").health.available, "未安装工具显示未连接")
                let qwenFile = events.appendingPathComponent("qwen-session.jsonl")
                let qwenStart: [String: Any] = ["sessionId": "native-qwen", "uuid": "u1", "type": "system", "subtype": "turn_attempt", "cwd": root.path, "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5))]
                let qwenEnd: [String: Any] = ["sessionId": "native-qwen", "uuid": "u2", "type": "system", "subtype": "turn_result", "cwd": root.path, "timestamp": ISO8601DateFormatter().string(from: Date()), "systemPayload": ["state": "completed", "promptText": "Native Qwen task", "endedAt": Date().timeIntervalSince1970 * 1000]]
                var qwenData = try JSONSerialization.data(withJSONObject: qwenStart); qwenData.append(0x0A); qwenData.append(try JSONSerialization.data(withJSONObject: qwenEnd)); try qwenData.write(to: qwenFile)
                check(readers.read(.qwen, path: events.path).tasks.first { $0.id == "qwen:native-qwen" }?.state == .completed, "Qwen 官方轮次事件标记完成")
                let qwenStartOnly = try JSONSerialization.data(withJSONObject: qwenStart); try qwenStartOnly.write(to: events.appendingPathComponent("qwen-running.jsonl"))
                check(readers.read(.qwen, path: events.path).tasks.first { $0.id == "qwen:native-qwen" }?.state == .completed, "旧事件不会覆盖较新的结束状态")
                let balance = BalanceService()
                let amount = await balance.number(at: "data.0.balance", in: ["data": [["balance": "12.35"]]])
                check(amount == 12.35, "余额 JSON 路径支持数组和数值字符串")
                let invalid = await balance.number(at: "valid", in: ["valid": true])
                check(invalid == nil, "布尔值不能被当作余额")
                let previous = Balance(id: "manual:bad", remaining: 88, unit: "CNY", updatedAt: Date())
                let queried = await balance.query(nil, custom: ManualAccount(id: "bad", name: "Bad", endpoint: "http://example.com", amountPath: "balance", unit: "CNY"), previous: previous)
                check(queried.remaining == 88 && queried.error != nil, "查询失败保留上次余额")
                let object = CCReader.credentials(["auth": ["OPENAI_API_KEY": "test-value"], "config": "base_url = \"https://example.com/v1\""])
                check(object.base == "https://example.com/v1" && object.key == "test-value", "从 Codex 配置提取查询参数")
                let encoded = try JSONEncoder().encode(BoardSnapshot.empty)
                let string = String(data: encoded, encoding: .utf8) ?? ""
                check(!string.contains("apiKey") && !string.contains("settings_config"), "共享快照没有凭据字段")
                try SharedStorage.write(BoardPreferences(), name: "prefs.json", directory: root)
                check(SharedStorage.read(BoardPreferences.self, name: "prefs.json", directory: root) != nil, "设置原子保存和读取")
                let codexRoot = root.appendingPathComponent("codex")
                try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
                let now = Int(Date().timeIntervalSince1970)
                let rollout = codexRoot.appendingPathComponent("rollout.jsonl")
                func writeCodexEvent(_ type: String, at date: Int, error: Bool = false) throws {
                    var payload: [String: Any] = ["type": type, "started_at": date]
                    if type == "task_complete" { payload["completed_at"] = date }
                    if error { payload["error"] = ["message": "fixture"] }
                    let data = try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(date))), "type": "event_msg", "payload": payload])
                    try data.write(to: rollout)
                }
                let codexPath = try database("codex/state_5.sqlite", sql: """
                CREATE TABLE threads (id TEXT,title TEXT,cwd TEXT,updated_at INT,rollout_path TEXT,archived INT);
                INSERT INTO threads VALUES ('live','Fixture','/tmp',\(now),'rollout.jsonl',0);
                INSERT INTO threads VALUES ('archived','Archived','/tmp',\(now),'',1);
                """)
                _ = try database("codex/thread_history_1.sqlite", sql: """
                CREATE TABLE thread_turns (thread_id TEXT,status TEXT,started_at INT,completed_at INT,rollout_ordinal INT);
                INSERT INTO thread_turns VALUES ('live','inProgress',\(now-5),NULL,20);
                INSERT INTO thread_turns VALUES ('live','completed',\(now-50),\(now-30),2);
                """)
                let codexReaders = AgentReaders()
                let live = codexReaders.read(.codex, path: codexRoot.path)
                check(live.health.available && live.tasks.count == 1 && live.tasks.first?.state == .running, "Codex 读取最新轮次并排除归档会话")
                try writeCodexEvent("task_complete", at: now)
                let eventReader = AgentReaders()
                check(eventReader.read(.codex, path: codexRoot.path).tasks.first?.state == .completed, "Codex 会话结束事件优先于滞后的数据库状态")
                var locked: OpaquePointer?; sqlite3_open(codexRoot.appendingPathComponent("thread_history_1.sqlite").path, &locked)
                defer { sqlite3_close(locked) }
                check(sqlite3_exec(locked, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK, "构造 Codex 轮次数据库被占用场景")
                let historyLocked = AgentReaders().read(.codex, path: codexRoot.path)
                check(historyLocked.health.available && historyLocked.tasks.first?.state == .completed, "轮次数据库被占用时回退事件且不会断开 Codex")
                sqlite3_exec(locked, "ROLLBACK", nil, nil, nil)
                var clock = Date()
                let resilient = AgentReaders(now: { clock })
                _ = resilient.read(.codex, path: codexRoot.path)
                var stateLock: OpaquePointer?; sqlite3_open(codexPath, &stateLock)
                defer { sqlite3_close(stateLock) }
                check(sqlite3_exec(stateLock, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK, "构造 Codex 会话数据库被占用场景")
                let retrying = resilient.read(.codex, path: codexRoot.path)
                check(retrying.health.available && retrying.health.isStale == true && retrying.tasks.count == 1, "短暂占用保留上次成功结果并明确标注重试")
                clock = clock.addingTimeInterval(31)
                let expired = resilient.read(.codex, path: codexRoot.path)
                check(!expired.health.available && expired.tasks.isEmpty, "超过 30 秒不再把旧数据当作连接成功")
                sqlite3_exec(stateLock, "ROLLBACK", nil, nil, nil)
                let recovered = resilient.read(.codex, path: codexRoot.path)
                check(recovered.health.available && recovered.health.isStale != true, "数据库恢复可读后自动重新连接")
                try FileManager.default.removeItem(at: codexRoot.appendingPathComponent("thread_history_1.sqlite"))
                try writeCodexEvent("task_started", at: now+1)
                check(AgentReaders().read(.codex, path: codexRoot.path).tasks.first?.state == .running, "缺少轮次数据库时由明确开始事件恢复运行状态")
                try writeCodexEvent("task_complete", at: now+2, error: true)
                check(AgentReaders().read(.codex, path: codexRoot.path).tasks.first?.state == .failed, "Codex 带错误的结束事件显示失败")
                check(CodexReader.lastLifecycleEvent("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}") == nil, "普通 assistant 消息不会被当作 Codex 完成事件")
                _ = try database("codex/state_6.sqlite", sql: "CREATE TABLE threads (id TEXT,title TEXT,updated_at INT); INSERT INTO threads VALUES ('new','Future',\(now));")
                let upgraded = AgentReaders().read(.codex, path: codexRoot.path)
                check(upgraded.health.available && upgraded.tasks.first?.id == "codex:new", "自动发现更新编号的 Codex 数据库并容忍可选列缺失")
                check(BoardIdentity.version.split(separator: ".").count == 3 && Int(BoardIdentity.build) != nil && BoardIdentity.author == "Lau Kachun" && BoardIdentity.copyright.contains("© 2026 Lau Kachun"), "应用版本与版权由 Bundle 构建信息统一提供")
                var legacy = BoardPreferences(); legacy.compact = true; legacy.selectedAccounts = ["kept"]; legacy.opacity = 0.81
                var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
                legacyJSON.removeValue(forKey: "mini")
                let migrated = try JSONDecoder().decode(BoardPreferences.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
                check(migrated.compact && migrated.selectedAccounts == ["kept"] && migrated.opacity == 0.81 && migrated.miniOptions.metric == .tasks, "旧版设置保留账号和外观并默认使用圆环")
                check(MiniPreferences(diameter: -5).safeDiameter == 40 && MiniPreferences(diameter: 500).safeDiameter == 56 && MiniPreferences(diameter: .nan).safeDiameter == 48, "圆环尺寸限制和非法值恢复")
                let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1920, y: -300, width: 1920, height: 1080)]
                var placementOK = true
                for screen in screens {
                    for x in [screen.minX, screen.midX, screen.maxX - 56] {
                        for y in [screen.minY, screen.midY, screen.maxY - 56] {
                            let badge = NSRect(x: x, y: y, width: 56, height: 56)
                            let detail = MiniGeometry.detailFrame(badge: badge, screen: screen)
                            placementOK = placementOK && screen.contains(detail) && !detail.intersects(badge)
                        }
                    }
                }
                check(placementOK, "悬停详情在屏幕各边角和负坐标显示器内且不遮挡圆环")
                let smallScreen = NSRect(x: -200, y: 20, width: 220, height: 300)
                check(smallScreen.contains(MiniGeometry.detailFrame(badge: NSRect(x: -150, y: 200, width: 56, height: 56), screen: smallScreen)), "小屏幕详情尺寸与位置自动适配")
                var miniPrefs = BoardPreferences(); miniPrefs.enabledAgents = ["codex"]
                miniPrefs.miniOptions = MiniPreferences(metric: .balance, accountID: "second")
                let apiAccounts = [APIAccount(id: "first", providerID: "a", appType: "codex", name: "First", balanceKind: "manual", current: true), APIAccount(id: "second", providerID: "b", appType: "dsh", name: "Second", balanceKind: "manual", current: false)]
                var miniSnapshot = BoardSnapshot.empty
                miniSnapshot.balances = [Balance(id: "first", remaining: 1, updatedAt: Date()), Balance(id: "second", remaining: 12.35, unit: "CNY", updatedAt: Date())]
                miniSnapshot.tasks = [AgentTask(id: "one", agent: .codex, title: "Running", project: "", state: .running, updatedAt: Date(), source: "test"), AgentTask(id: "two", agent: .qwen, title: "Disabled", project: "", state: .waiting, updatedAt: Date(), source: "test")]
                let chosen = MiniReadout(snapshot: miniSnapshot, preferences: miniPrefs, accounts: apiAccounts)
                check(chosen.value == "¥12.35" && chosen.account?.id == "second", "圆环使用独立选择的 API 余额和币种")
                miniPrefs.miniOptions.accountID = "removed"
                check(MiniReadout(snapshot: miniSnapshot, preferences: miniPrefs, accounts: apiAccounts).account?.id == "first", "账号取消选择后回退到首个所选账号")
                miniPrefs.miniOptions.metric = .tasks
                let taskReadout = MiniReadout(snapshot: miniSnapshot, preferences: miniPrefs, accounts: [])
                check(taskReadout.value == "1" && !taskReadout.warning, "迷你任务数仅统计启用的 Agent")
                miniPrefs.miniOptions.metric = .balance
                check(MiniReadout(snapshot: miniSnapshot, preferences: miniPrefs, accounts: []).value == "—", "未选择余额账号时不使用其他账号数据")
                check(MiniReadout.shortMoney(12345, unit: "USD") == "$12.3K", "大额余额缩写适合小圆环")
                let testStore = BoardStore(); testStore.preferences = BoardPreferences(); testStore.snapshot = miniSnapshot
                let controller = MiniPanelController(store: testStore, persistPosition: false)
                let anchor = NSScreen.main?.visibleFrame ?? screens[0]
                controller.apply(preferences: testStore.preferences, visible: true, anchor: NSRect(x: anchor.midX, y: anchor.midY, width: 200, height: 200))
                check(controller.badge.frame.size == NSSize(width: 56, height: 56), "默认迷你窗口实际仅为 56×56 点")
                var pointer = NSPoint(x: controller.badge.frame.midX, y: controller.badge.frame.midY)
                controller.pointerLocation = { pointer }
                let keyWindow = NSApp.keyWindow
                controller.badgeHoverChanged(true)
                try await Task.sleep(nanoseconds: 100_000_000)
                check(!controller.isDetailVisible, "短暂划过圆环不会立即弹出")
                try await Task.sleep(nanoseconds: 230_000_000)
                check(controller.isDetailVisible && NSApp.keyWindow === keyWindow, "悬停显示详情且不抢键盘焦点")
                controller.badgeHoverChanged(false)
                pointer = NSPoint(x: controller.detail.frame.midX, y: controller.detail.frame.midY); controller.detailHoverChanged(true)
                try await Task.sleep(nanoseconds: 450_000_000)
                check(controller.isDetailVisible, "鼠标从圆环移入详情时保持展开")
                pointer = NSPoint(x: anchor.minX - 500, y: anchor.minY - 500); controller.detailHoverChanged(false)
                try await Task.sleep(nanoseconds: 500_000_000)
                check(!controller.isDetailVisible, "鼠标移开后自动收起详情")
                pointer = NSPoint(x: controller.badge.frame.midX, y: controller.badge.frame.midY)
                controller.badgeHoverChanged(true); controller.draggingChanged(true)
                try await Task.sleep(nanoseconds: 350_000_000)
                check(!controller.isDetailVisible, "拖动圆环时取消待弹出的详情")
                controller.draggingChanged(false); controller.badgeHoverChanged(true); controller.hide()
                try await Task.sleep(nanoseconds: 350_000_000)
                check(!controller.badge.isVisible && !controller.isDetailVisible, "隐藏迷你模式取消悬停回调及两个窗口")
                try FeatureTests.run(root: root, check: { condition, name in check(condition, name) })
            } catch { failures.append(error.localizedDescription) }
            print("\(passed) passed, \(failures.count) failed")
            failures.forEach { print("FAIL " + $0) }; exit(failures.isEmpty ? 0 : 1)
        }
    }
}

enum SnapshotRenderer {
    @MainActor static func run(delegate: AppDelegate) {
        Task { @MainActor in
            let store = delegate.store
            var snapshot = await MonitorEngine().poll(store.preferences, force: true)
            snapshot.balances = store.snapshot.balances; store.snapshot = snapshot
            let args = CommandLine.arguments
            let path = args.firstIndex(of: "--snapshot-output").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "/tmp/agentboard-snapshots"
            let root = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            @MainActor func save(_ view: NSView, _ name: String) {
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: root.appendingPathComponent(name + ".png")); print("SNAPSHOT " + name) }
            }
            let panel = delegate.panel!
            store.preferences.compact = false
            let sizes: [(String, NSSize)] = [("float-narrow", NSSize(width: 290, height: 680)), ("float-standard", NSSize(width: 380, height: 760)), ("float-wide", NSSize(width: 800, height: 650)), ("float-short", NSSize(width: 290, height: 180))]
            for (name, size) in sizes {
                panel.setContentSize(size); panel.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 450_000_000)
                if let view = panel.contentView { save(view, name) }
            }
            let expandedFrame = panel.frame
            store.preferences.compact = true; delegate.applyPreferences()
            let mini = delegate.miniController!
            var pointer = NSPoint(x: mini.badge.frame.midX, y: mini.badge.frame.midY)
            mini.pointerLocation = { pointer }
            for metric in MiniMetric.allCases {
                store.preferences.miniOptions = MiniPreferences(metric: metric)
                delegate.applyPreferences(); mini.dismissDetail()
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let view = mini.badge.contentView { save(view, "mini-" + metric.rawValue) }
            }
            for (name, options) in [("mini-smallest", MiniPreferences(metric: .tokens, diameter: 40)), ("mini-largest", MiniPreferences(metric: .balance, diameter: 56)), ("mini-capsule", MiniPreferences(metric: .costAndBalance, shape: .capsule))] {
                store.preferences.miniOptions = options; delegate.applyPreferences()
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let view = mini.badge.contentView { save(view, name) }
            }
            store.preferences.miniOptions = MiniPreferences(metric: .tasks); delegate.applyPreferences()
            pointer = NSPoint(x: mini.badge.frame.midX, y: mini.badge.frame.midY)
            mini.badgeHoverChanged(true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard mini.isDetailVisible, !panel.isVisible else { print("FAIL 迷你窗口切换与悬停"); exit(1) }
            if let view = mini.detail.contentView { save(view, "mini-hover") }
            mini.dismissDetail(); store.preferences.compact = false; delegate.applyPreferences()
            guard panel.frame.size == expandedFrame.size, !mini.badge.isVisible else { print("FAIL 展开窗口尺寸恢复"); exit(1) }
            print("PASS 迷你模式不改变完整浮窗尺寸")
            for tab in 0...5 {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 670), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: BoardSettingsView(selectedTab: tab).environmentObject(store)); window.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 450_000_000)
                if let view = window.contentView { save(view, "settings-\(tab)") }; window.orderOut(nil)
            }
            let originalTheme = store.preferences.theme
            for (name, theme) in [ThemeSettings.presets[1], ThemeSettings.presets[2], ThemeSettings.presets[4]] {
                store.preferences.themeOptions = theme; store.preferences.compact = true; delegate.applyPreferences()
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let view = mini.badge.contentView { save(view, "theme-" + name + "-ring") }
                mini.showDetail(); try? await Task.sleep(nanoseconds: 200_000_000)
                if let view = mini.detail.contentView { save(view, "theme-" + name + "-hover") }; mini.dismissDetail()
            }
            store.preferences.compact = false; delegate.applyPreferences()
            panel.setContentSize(NSSize(width: 380, height: 760)); panel.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let view = panel.contentView { save(view, "theme-paper-dashboard") }
            let paperSettings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 670), styleMask: [.titled], backing: .buffered, defer: false)
            paperSettings.contentView = NSHostingView(rootView: BoardSettingsView(selectedTab: 0).environmentObject(store)); paperSettings.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let view = paperSettings.contentView { save(view, "theme-paper-settings") }; paperSettings.orderOut(nil)
            store.preferences.theme = originalTheme; delegate.applyPreferences()
            let guide = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 556, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
            guide.contentView = NSHostingView(rootView: OnboardingView().environmentObject(store)); guide.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let view = guide.contentView { save(view, "onboarding") }; guide.orderOut(nil)
            for (name, family, size) in [("small", WidgetFamily.systemSmall, NSSize(width: 170, height: 170)), ("medium", .systemMedium, NSSize(width: 364, height: 170)), ("large", .systemLarge, NSSize(width: 364, height: 382)), ("paper", .systemLarge, NSSize(width: 364, height: 382))] {
                let configuration = BoardWidgetIntent()
                var widgetSnapshot = snapshot
                widgetSnapshot.accounts = store.selectedAccounts
                widgetSnapshot.theme = name == "paper" ? ThemeSettings.presets[4].1 : store.preferences.themeOptions
                let entry = BoardEntry(date: Date(), configuration: configuration, snapshot: widgetSnapshot, preferences: store.preferences)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: BoardWidgetView(entry: entry, previewFamily: family).padding(16).background(BoardPalette(widgetSnapshot.theme ?? ThemeSettings()).background).preferredColorScheme(name == "paper" ? .light : .dark))
                window.orderFrontRegardless(); try? await Task.sleep(nanoseconds: 400_000_000)
                if let view = window.contentView { save(view, "widget-" + name) }; window.orderOut(nil)
            }
            print("Snapshots: " + path); exit(0)
        }
    }
}
