import Foundation

/// Reads only local metadata and explicit lifecycle events. No credentials or networking.
final class CodexReader {
    private var eventCache: [String: (Date, CodexTurnEvent?)] = [:]
    struct CodexTurnEvent {
        var state: TaskState
        var date: Date
        var startedAt: Date?
    }
    static func databasePath(root: String, prefix: String) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(atPath: root)
        let candidates = files.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix + "_"), name.hasSuffix(".sqlite"), let version = Int(name.dropFirst(prefix.count + 1).dropLast(7)) else { return nil }
            return (version, name)
        }.sorted { $0.0 > $1.0 }
        guard let name = candidates.first?.1 else { throw ReaderError.message("未找到 Codex \(prefix)_*.sqlite，请确认数据目录") }
        return URL(fileURLWithPath: root).appendingPathComponent(name).path
    }
    func read(_ root: String) throws -> [AgentTask] {
        let path = try Self.databasePath(root: root, prefix: "state")
        let db = try ReadOnlyDatabase(path)
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        guard columns.contains("id") else { throw ReaderError.message("Codex 会话表暂不兼容，请更新 AgentBoard") }
        let fields = ["id", "title", "name", "cwd", "updated_at", "updated_at_ms", "rollout_path", "tokens_used"].filter { columns.contains($0) }
        let order = columns.contains("updated_at_ms") ? "updated_at_ms" : (columns.contains("updated_at") ? "updated_at" : "id")
        let rows = try db.rows("SELECT " + fields.joined(separator: ",") + " FROM threads" + (columns.contains("archived") ? " WHERE archived = 0" : "") + " ORDER BY " + order + " DESC LIMIT 60")
        let history = (try? Self.databasePath(root: root, prefix: "thread_history")).flatMap { try? ReadOnlyDatabase($0) }
        var turns: [String: [String: String]] = [:]
        if let history {
            let historyColumns = Set((try? history.rows("PRAGMA table_info(thread_turns)"))?.compactMap { $0["name"] } ?? [])
            if historyColumns.contains("thread_id") && historyColumns.contains("status") && !rows.isEmpty {
                let selected = ["thread_id", "status", "started_at", "completed_at", "rollout_ordinal"].filter { historyColumns.contains($0) }
                let order = historyColumns.contains("rollout_ordinal") ? "rollout_ordinal" : (historyColumns.contains("started_at") ? "started_at" : "rowid")
                let placeholders = Array(repeating: "?", count: rows.count).joined(separator: ",")
                if let all = try? history.rows("SELECT " + selected.joined(separator: ",") + " FROM thread_turns WHERE thread_id IN (" + placeholders + ") ORDER BY " + order + " DESC", parameters: rows.compactMap { $0["id"] }) {
                    for turn in all { if let id = turn["thread_id"], turns[id] == nil { turns[id] = turn } }
                }
            }
        }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            let turn = turns[id]
            var rollout = row["rollout_path"] ?? ""
            if !rollout.isEmpty && !rollout.hasPrefix("/") { rollout = URL(fileURLWithPath: root).appendingPathComponent(rollout).path }
            let activity = (try? FileManager.default.attributesOfItem(atPath: rollout)[.modificationDate]) as? Date
            let updated = max(activity ?? .distantPast, max(timeValue(row["updated_at_ms"]) ?? .distantPast, timeValue(row["updated_at"]) ?? .distantPast))
            var state = AgentReaders().normalized(turn?["status"] ?? "unknown")
            var started = timeValue(turn?["started_at"])
            var source = "本地轮次数据库", detail = ""
            // The projection database can lag behind the durable rollout or be migrating.
            // Newer explicit events resolve that gap; ordinary message activity is ignored.
            let event = lifecycle(path: rollout, modified: activity)
            let turnDate = timeValue(turn?["completed_at"] ?? turn?["started_at"]) ?? .distantPast
            if let event, state == .unknown || event.date > turnDate {
                state = event.state; started = event.startedAt ?? started; source = "Codex 会话轮次事件"
            } else if turn == nil { detail = "轮次数据库暂不可用，等待可识别的会话事件" }
            if state.active && Date().timeIntervalSince(updated) > 600 { state = .unknown; detail = "轮次尚未结束，但已超过 10 分钟没有活动" }
            let title = row["name"].flatMap { $0.isEmpty ? nil : $0 } ?? row["title"] ?? "Codex 会话"
            return AgentTask(id: "codex:" + id, agent: .codex, title: String(title.replacingOccurrences(of: "\n", with: " ").prefix(180)), project: row["cwd"] ?? "", state: state, updatedAt: updated, startedAt: started, source: source, sourcePath: rollout.isEmpty ? nil : rollout, detail: detail, sessionTokens: row["tokens_used"].flatMap(Int64.init))
        }
    }
    private func lifecycle(path: String, modified: Date?) -> CodexTurnEvent? {
        guard !path.isEmpty, let modified else { return nil }
        if let cached = eventCache[path], cached.0 == modified { return cached.1 }
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return nil }
        let limit: UInt64 = 4_000_000
        try? file.seek(toOffset: end > limit ? end - limit : 0)
        guard let data = try? file.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let event = Self.lastLifecycleEvent(text)
        eventCache[path] = (modified, event)
        return event
    }
    static func lastLifecycleEvent(_ text: String) -> CodexTurnEvent? {
        for line in text.split(separator: "\n").reversed() {
            let object = jsonObject(String(line))
            guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any], let type = payload["type"] as? String else { continue }
            let state: TaskState
            switch type {
            case "task_started": state = .running
            case "task_complete": state = payload["error"] != nil && !(payload["error"] is NSNull) ? .failed : .completed
            case "turn_aborted": state = .interrupted
            default: continue
            }
            guard let date = dateValue(payload["completed_at"] ?? payload["started_at"] ?? object["timestamp"]) else { continue }
            return CodexTurnEvent(state: state, date: date, startedAt: dateValue(payload["started_at"]))
        }
        return nil
    }
}
