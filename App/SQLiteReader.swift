import Foundation
import SQLite3

enum ReaderError: LocalizedError {
    case message(String)
    case databaseBusy
    var errorDescription: String? { switch self { case .message(let text): return text; case .databaseBusy: return "数据库正在更新，稍后自动重试" } }
}

final class ReadOnlyDatabase {
    private var db: OpaquePointer?
    init(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw ReaderError.message("找不到数据库") }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        var status = sqlite3_open_v2(path, &db, flags, nil)
        // Closed WAL databases can lack SHM files. Immutable is safe only with no WAL.
        if status != SQLITE_OK && !FileManager.default.fileExists(atPath: path + "-wal") {
            sqlite3_close(db); db = nil
            var c = URLComponents(); c.scheme = "file"; c.path = path; c.query = "mode=ro&immutable=1"
            status = sqlite3_open_v2(c.string, &db, flags, nil)
        }
        guard status == SQLITE_OK else { sqlite3_close(db); db = nil; throw ReaderError.message("无法只读打开数据库（\(status)）") }
        sqlite3_busy_timeout(db, 600)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, parameters: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            if prepared & 0xff == SQLITE_BUSY || prepared & 0xff == SQLITE_LOCKED { throw ReaderError.databaseBusy }
            throw ReaderError.message("数据库结构暂不兼容")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                if status & 0xff == SQLITE_BUSY || status & 0xff == SQLITE_LOCKED { throw ReaderError.databaseBusy }
                throw ReaderError.message("数据库读取失败（\(status)）")
            }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, i), let value = sqlite3_column_text(statement, i) else { continue }
                row[String(cString: name)] = String(cString: value)
            }
            result.append(row)
        }
        return result
    }
}

func jsonObject(_ string: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] ?? [:] }
func timeValue(_ raw: String?) -> Date? {
    guard let raw, let n = Double(raw) else { return nil }
    return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
}
func dateValue(_ value: Any?) -> Date? {
    if let number = value as? NSNumber { return timeValue(number.stringValue) }
    if let string = value as? String {
        if let date = timeValue(string) { return date }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    return nil
}

struct ProviderRecord {
    var account: APIAccount
    var config: [String: Any]
    var meta: [String: Any]
}

enum CCReader {
    static func providers(path: String) throws -> [ProviderRecord] {
        let db = try ReadOnlyDatabase((path as NSString).expandingTildeInPath)
        return try db.rows("SELECT id, app_type, name, settings_config, meta, is_current FROM providers ORDER BY sort_index, name").map { r in
            let app = r["app_type"] ?? "unknown", id = r["id"] ?? ""
            let config = jsonObject(r["settings_config"] ?? "{}"), meta = jsonObject(r["meta"] ?? "{}")
            let script = meta["usage_script"] as? [String: Any] ?? [:]
            let template = script["templateType"] as? String ?? ""
            let base = credentials(config).base
            let kind = (script["enabled"] as? Bool == true && template == "sub2api") ? "sub2api" : (URL(string: base)?.host == "api.deepseek.com" ? "deepseek" : "unsupported")
            return ProviderRecord(account: APIAccount(id: app + ":" + id, providerID: id, appType: app, name: r["name"] ?? app, balanceKind: kind, current: r["is_current"] == "1"), config: config, meta: meta)
        }
    }
    static func usage(path: String, accounts: [APIAccount], now: Date = Date()) throws -> (Usage, [APIAccount]) {
        let db = try ReadOnlyDatabase((path as NSString).expandingTildeInPath)
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!.timeIntervalSince1970
        // CC Switch moves historical rows into rollups. Prefer raw data for overlapping buckets.
        let rows = try db.rows("SELECT app_type, provider_id, SUM(input_tokens) AS i, SUM(output_tokens) AS o, SUM(cache_read_tokens) AS r, SUM(cache_creation_tokens) AS w, SUM(CAST(total_cost_usd AS REAL)) AS c, COUNT(*) AS n, MAX(created_at) AS latest FROM proxy_request_logs WHERE created_at >= ? AND created_at < ? GROUP BY app_type, provider_id", parameters: [String(Int(start)), String(Int(end))])
        var buckets: [String: Usage] = [:]
        for r in rows {
            let id = (r["app_type"] ?? "") + ":" + (r["provider_id"] ?? "")
            buckets[id] = Usage(input: Int64(r["i"] ?? "") ?? 0, output: Int64(r["o"] ?? "") ?? 0, cacheRead: Int64(r["r"] ?? "") ?? 0, cacheWrite: Int64(r["w"] ?? "") ?? 0, cost: Double(r["c"] ?? "") ?? 0, requests: Int(r["n"] ?? "") ?? 0, latestAt: timeValue(r["latest"]))
        }
        // Existing database schemas may not contain rollups; absence is harmless.
        if let rollups = try? db.rows("SELECT app_type,provider_id,SUM(input_tokens) AS i,SUM(output_tokens) AS o,SUM(cache_read_tokens) AS r,SUM(cache_creation_tokens) AS w,SUM(CAST(total_cost_usd AS REAL)) AS c,SUM(request_count) AS n FROM usage_daily_rollups WHERE date = ? GROUP BY app_type,provider_id", parameters: [BoardFormat.day(now)]) {
            for r in rollups {
                let id = (r["app_type"] ?? "") + ":" + (r["provider_id"] ?? "")
                if buckets[id] == nil { buckets[id] = Usage(input: Int64(r["i"] ?? "") ?? 0, output: Int64(r["o"] ?? "") ?? 0, cacheRead: Int64(r["r"] ?? "") ?? 0, cacheWrite: Int64(r["w"] ?? "") ?? 0, cost: Double(r["c"] ?? "") ?? 0, requests: Int(r["n"] ?? "") ?? 0) }
            }
        }
        var all = Usage(); for value in buckets.values { all.add(value) }
        let updated = accounts.map { a -> APIAccount in var a = a; a.usage = buckets[a.id] ?? Usage(); return a }
        return (all, updated)
    }
    static func credentials(_ config: [String: Any]) -> (base: String, key: String) {
        let auth = config["auth"] as? [String: Any] ?? [:]
        let env = config["env"] as? [String: Any] ?? [:]
        let options = config["options"] as? [String: Any] ?? [:]
        let toml = config["config"] as? String ?? ""
        var base = config["baseURL"] as? String ?? options["baseURL"] as? String ?? env["ANTHROPIC_BASE_URL"] as? String ?? env["OPENAI_BASE_URL"] as? String ?? ""
        if base.isEmpty, let range = toml.range(of: #"base_url\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
            let match = String(toml[range]); base = match.components(separatedBy: CharacterSet(charactersIn: "\"'")).dropFirst().first ?? ""
        }
        let key = auth["OPENAI_API_KEY"] as? String ?? options["apiKey"] as? String ?? env["ANTHROPIC_AUTH_TOKEN"] as? String ?? env["ANTHROPIC_API_KEY"] as? String ?? env["OPENAI_API_KEY"] as? String ?? ""
        return (base, key)
    }
}
