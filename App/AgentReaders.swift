import Foundation

struct AgentReadResult { var tasks: [AgentTask]; var health: AgentHealth }

final class AgentReaders {
    private var fileCache: [String: (Date, [AgentTask])] = [:]
    private let codexReader = CodexReader()
    private var lastCodex: (date: Date, path: String, tasks: [AgentTask])?
    private let now: () -> Date
    private var successDates: [String: Date] = [:]
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    func read(_ kind: AgentKind, path: String) -> AgentReadResult {
        var result = readSource(kind, path: path)
        let key = kind.rawValue + ":" + path
        result.health.checkedAt = now()
        if result.health.available && result.health.isStale != true { successDates[key] = now() }
        result.health.lastSuccessAt = successDates[key]
        return result
    }
    private func readSource(_ kind: AgentKind, path: String) -> AgentReadResult {
        guard FileManager.default.fileExists(atPath: path) else { return AgentReadResult(tasks: [], health: AgentHealth(agent: kind, available: false, message: "未发现数据目录，可在设置中指定路径", category: .notInstalled)) }
        do {
            let tasks: [AgentTask]
            switch kind {
            case .codex: tasks = try codexReader.read(path)
            case .workbuddy: tasks = try workbuddy(path)
            case .dsh: tasks = try dsh(path)
            case .qwen, .claude, .custom: tasks = try eventFiles(kind, path: path)
            }
            if kind == .codex { lastCodex = (now(), path, tasks) }
            return AgentReadResult(tasks: tasks, health: AgentHealth(agent: kind, available: true, message: tasks.isEmpty ? (kind == .qwen || kind == .claude || kind == .custom ? "目录已连接，等待事件或可识别的会话记录" : "已连接，暂无任务") : "已读取 \(tasks.count) 个会话", category: .connected))
        } catch {
            if kind == .codex, case ReaderError.databaseBusy = error, let lastCodex, path == lastCodex.path, now().timeIntervalSince(lastCodex.date) <= 30 {
                return AgentReadResult(tasks: lastCodex.tasks, health: AgentHealth(agent: kind, available: true, message: "Codex 数据库更新中，暂显上次结果，将自动重试", isStale: true, category: .busy))
            }
            let category: ConnectionCategory
            if case ReaderError.databaseBusy = error { category = .busy }
            else if error.localizedDescription.contains("不兼容") { category = .incompatible }
            else if error.localizedDescription.contains("找不到") || error.localizedDescription.contains("未找到") { category = .missingData }
            else { category = .unreadable }
            return AgentReadResult(tasks: [], health: AgentHealth(agent: kind, available: false, message: error.localizedDescription, category: category))
        }
    }
    private func workbuddy(_ path: String) throws -> [AgentTask] {
        let db = try ReadOnlyDatabase(path + "/workbuddy.db")
        return try db.rows("SELECT id,title,custom_title,cwd,status,updated_at,last_activity_at,created_at FROM sessions WHERE deleted_at IS NULL AND lower(status) != 'archived' ORDER BY updated_at DESC LIMIT 60").map { row in
            var state = normalized(row["status"] ?? "")
            let updated = timeValue(row["last_activity_at"]) ?? timeValue(row["updated_at"]) ?? .distantPast
            var detail = ""
            if state.active && Date().timeIntervalSince(updated) > 600 { state = .unknown; detail = "会话仍标记为运行，最近活动已过期" }
            let custom = row["custom_title"] ?? ""
            return AgentTask(id: "workbuddy:" + (row["id"] ?? ""), agent: .workbuddy, title: cleanTitle(custom.isEmpty ? row["title"] ?? "WorkBuddy 会话" : custom), project: row["cwd"] ?? "", state: state, updatedAt: updated, startedAt: timeValue(row["created_at"]), source: "本地会话数据库", sourcePath: path + "/tasks/" + (row["id"] ?? ""), detail: detail)
        }
    }
    private func dsh(_ path: String) throws -> [AgentTask] {
        let root = URL(fileURLWithPath: path + "/sessions")
        let files = recentFiles(root, suffixes: ["zstd", "jsonl"], limit: 30)
        var tasks: [AgentTask] = []
        for file in files {
            let modified = modification(file)
            if let cached = fileCache[file.path], cached.0 == modified {
                tasks += cached.1.map { item in var item = item; if item.state.active && Date().timeIntervalSince(item.updatedAt) > 600 { item.state = .unknown }; return item }
                continue
            }
            let text: String
            if file.pathExtension == "zstd" {
                guard let binary = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ReaderError.message("需要 zstd 才能读取 Harness 的压缩会话") }
                text = try decompress(binary, file: file)
            } else { text = try String(contentsOf: file, encoding: .utf8) }
            var title = "Harness 会话", project = "", state = TaskState.idle, started: Date?, updated = modified
            for line in text.split(separator: "\n") {
                let object = jsonObject(String(line)), type = object["type"] as? String ?? ""
                let data = object["data"] as? [String: Any] ?? [:]
                if type == "session" { project = object["cwd"] as? String ?? "" }
                if type == "session/title" { title = data["title"] as? String ?? title }
                if let date = dateValue(object["time"]) { updated = date }
                if type == "turn/start" { state = .running; started = dateValue(object["time"]) }
                if type == "turn/end" {
                    let reason = String(describing: data["reason"] ?? "").lowercased()
                    state = reason.contains("error") || reason.contains("fail") ? .failed : (reason.contains("abort") || reason.contains("interrupt") || reason.contains("cancel") ? .interrupted : .completed)
                }
                if ["approval/request", "permission/request"].contains(type) { state = .waiting }
                if ["approval/response", "permission/response"].contains(type), state == .waiting { state = .running }
            }
            if state.active && Date().timeIntervalSince(modified) > 600 { state = .unknown }
            let item = AgentTask(id: "dsh:" + file.deletingLastPathComponent().lastPathComponent, agent: .dsh, title: cleanTitle(title), project: project, state: state, updatedAt: updated, startedAt: started, source: "Harness 会话事件", sourcePath: file.path)
            fileCache[file.path] = (modified, [item]); tasks.append(item)
        }
        return tasks
    }
    private func eventFiles(_ kind: AgentKind, path: String) throws -> [AgentTask] {
        // A public event inbox also supports tools without a stable local state database.
        // Never infer completion solely from an assistant message or silence.
        let root = URL(fileURLWithPath: path)
        let files = recentFiles(root, suffixes: ["json", "jsonl"], limit: 40).filter { !["auth.json", "settings.json", "credentials.json"].contains($0.lastPathComponent) }
        var tasks: [String: AgentTask] = [:]
        for file in files {
            let modified = modification(file)
            if let cache = fileCache[file.path], cache.0 == modified { for t in cache.1 where t.updatedAt >= (tasks[t.id]?.updatedAt ?? .distantPast) { tasks[t.id] = t }; continue }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000 else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = file.pathExtension == "jsonl" ? text.components(separatedBy: "\n") : [text]
            var local: [String: AgentTask] = [:]
            for line in lines {
                let o = jsonObject(line)
                if o["schema"] as? String == "agentboard.v1", let id = o["taskId"] as? String {
                    let state = normalized(o["state"] as? String ?? "unknown")
                    let agent = AgentKind(rawValue: o["agent"] as? String ?? "") ?? kind
                    let key = agent.rawValue + ":" + id
                    let item = AgentTask(id: key, agent: agent, title: cleanTitle(o["title"] as? String ?? "Agent 任务"), project: o["project"] as? String ?? "", state: state, updatedAt: dateValue(o["updatedAt"]) ?? modified, startedAt: dateValue(o["startedAt"]), source: "AgentBoard 事件", sourcePath: file.path)
                    if item.updatedAt >= (local[key]?.updatedAt ?? .distantPast) { local[key] = item }
                }
                // Claude JSONL gives content activity, but no reliable end-of-turn event.
                if kind == .claude, let id = o["sessionId"] as? String, let type = o["type"] as? String, ["user", "assistant"].contains(type) {
                    let key = "claude:" + id
                    local[key] = AgentTask(id: key, agent: kind, title: "Claude Code · " + (o["cwd"] as? String ?? file.deletingLastPathComponent().lastPathComponent).components(separatedBy: "/").last!, project: o["cwd"] as? String ?? "", state: .unknown, updatedAt: dateValue(o["timestamp"]) ?? modified, source: "会话活动（无结束事件）", sourcePath: file.path, detail: "精确状态可通过事件文件接入")
                }
                // Qwen/Gemini-compatible JSON session format. Activity is explicit; task state is unknown.
                if kind == .qwen, let id = o["sessionId"] as? String, o["messages"] is [Any] {
                    let key = "qwen:" + id
                    local[key] = AgentTask(id: key, agent: kind, title: o["title"] as? String ?? "Qwen Code 会话", project: o["projectHash"] as? String ?? "", state: .unknown, updatedAt: dateValue(o["lastUpdated"]) ?? modified, source: "会话快照（无结束事件）", sourcePath: file.path)
                }
                // Qwen Code's official ChatRecord format includes durable turn_result records.
                if kind == .qwen, let id = o["sessionId"] as? String, let type = o["type"] as? String, ["user", "assistant", "tool_result", "system"].contains(type), o["uuid"] is String {
                    let key = "qwen:" + id, subtype = o["subtype"] as? String ?? ""
                    let payload = o["systemPayload"] as? [String: Any] ?? [:]
                    var item = local[key] ?? AgentTask(id: key, agent: kind, title: "Qwen Code 会话", project: o["cwd"] as? String ?? "", state: .unknown, updatedAt: modified, source: "Qwen 会话事件", sourcePath: file.path)
                    item.updatedAt = dateValue(o["timestamp"]) ?? modified
                    if subtype == "custom_title", let title = payload["customTitle"] as? String { item.title = cleanTitle(title) }
                    if subtype == "turn_attempt" { item.state = .running; item.startedAt = item.updatedAt }
                    if subtype == "turn_result" {
                        item.state = normalized(payload["state"] as? String ?? "unknown")
                        item.startedAt = dateValue(payload["startedAt"])
                        if let title = payload["promptText"] as? String { item.title = cleanTitle(title) }
                    } else if type == "user" && subtype.isEmpty {
                        // A user message indicates activity, but does not prove execution was admitted.
                        item.state = .unknown
                    }
                    local[key] = item
                }
            }
            fileCache[file.path] = (modified, Array(local.values))
            for (id, item) in local where item.updatedAt >= (tasks[id]?.updatedAt ?? .distantPast) { tasks[id] = item }
        }
        return Array(tasks.values).map { task in
            var task = task
            if task.state.active && Date().timeIntervalSince(task.updatedAt) > 600 { task.state = .unknown; task.detail = "事件已超过 10 分钟未更新" }
            return task
        }
    }
    func normalized(_ raw: String) -> TaskState {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "inprogress", "running", "executing", "active": return .running
        case "waiting", "waitingforapproval", "needsapproval", "awaitinginput", "requiresaction": return .waiting
        case "completed", "complete", "done", "success": return .completed
        case "failed", "error": return .failed
        case "interrupted", "cancelled", "canceled", "aborted": return .interrupted
        case "idle", "pending": return .idle
        default: return .unknown
        }
    }
    private func cleanTitle(_ title: String) -> String { String(title.replacingOccurrences(of: "\n", with: " ").prefix(180)) }
    private func modification(_ file: URL) -> Date { (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    private func recentFiles(_ root: URL, suffixes: [String], limit: Int) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []; var visited = 0
        for case let file as URL in e {
            visited += 1; if visited > 15_000 { break }
            if suffixes.contains(file.pathExtension), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(file) }
        }
        return Array(result.sorted { modification($0) > modification($1) }.prefix(limit))
    }
    private func decompress(_ binary: String, file: URL) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: binary); p.arguments = ["-dc", "--", file.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 32_000_000 { p.terminate(); p.waitUntilExit(); throw ReaderError.message("会话文件过大，暂不读取") }
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { throw ReaderError.message("压缩会话暂不可读") }
        return text
    }
}
