import Foundation

enum UsageAnalytics {
    static func read(path: String, now: Date = Date()) throws -> UsageStatistics {
        let db = try ReadOnlyDatabase((path as NSString).expandingTildeInPath)
        let start = min(UsagePeriod.week.start(now: now), UsagePeriod.month.start(now: now))
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let columns = Set(try db.rows("PRAGMA table_info(proxy_request_logs)").compactMap { $0["name"] })
        let model = columns.contains("model") ? "COALESCE(NULLIF(model,''),'未记录模型')" : "'未记录模型'"
        let sums = "SUM(input_tokens) AS i,SUM(output_tokens) AS o,SUM(cache_read_tokens) AS r,SUM(cache_creation_tokens) AS w,SUM(CAST(total_cost_usd AS REAL)) AS c"
        let params = [String(Int(start.timeIntervalSince1970)), String(Int(end.timeIntervalSince1970))]
        let rows = try db.rows("SELECT date(created_at,'unixepoch','localtime') AS day,app_type,provider_id," + model + " AS model," + sums + ",COUNT(*) AS n FROM proxy_request_logs WHERE created_at >= ? AND created_at < ? GROUP BY day,app_type,provider_id,4", parameters: params)
        var buckets: [String: UsageBucket] = [:]
        for row in rows { let bucket = bucket(row); buckets[bucket.id] = bucket }
        var notes: [String] = []
        let rollupColumns = Set((try? db.rows("PRAGMA table_info(usage_daily_rollups)"))?.compactMap { $0["name"] } ?? [])
        if !rollupColumns.isEmpty {
            let rollupModel = rollupColumns.contains("model") ? "COALESCE(NULLIF(model,''),'未记录模型')" : "'未记录模型'"
            let rollups = try db.rows("SELECT date AS day,app_type,provider_id," + rollupModel + " AS model," + sums + ",SUM(request_count) AS n FROM usage_daily_rollups WHERE date >= ? AND date <= ? GROUP BY date,app_type,provider_id,4", parameters: [BoardFormat.day(start), BoardFormat.day(now)])
            for row in rollups {
                let bucket = bucket(row)
                if buckets[bucket.id] == nil { buckets[bucket.id] = bucket }
                else { notes = ["明细和汇总重叠的日期／账号／模型仅取明细，避免重复计数。"] }
            }
        }
        var sessions: [String: Usage] = [:]
        if columns.contains("session_id") {
            let rows = try db.rows("SELECT app_type,session_id," + sums + ",COUNT(*) AS n FROM proxy_request_logs WHERE created_at >= ? AND created_at < ? AND session_id IS NOT NULL AND session_id != '' GROUP BY app_type,session_id", parameters: params)
            for row in rows { sessions[(row["app_type"] ?? "") + ":" + (row["session_id"] ?? "")] = usage(row) }
        }
        return UsageStatistics(updatedAt: now, buckets: buckets.values.sorted { $0.id < $1.id }, sessionUsage: sessions, notes: notes)
    }
    private static func usage(_ row: [String: String]) -> Usage {
        Usage(input: Int64(row["i"] ?? "") ?? 0, output: Int64(row["o"] ?? "") ?? 0, cacheRead: Int64(row["r"] ?? "") ?? 0, cacheWrite: Int64(row["w"] ?? "") ?? 0, cost: Double(row["c"] ?? "") ?? 0, requests: Int(row["n"] ?? "") ?? 0)
    }
    private static func bucket(_ row: [String: String]) -> UsageBucket {
        UsageBucket(day: row["day"] ?? "", accountID: (row["app_type"] ?? "") + ":" + (row["provider_id"] ?? ""), model: row["model"] ?? "未记录模型", usage: usage(row))
    }
}
