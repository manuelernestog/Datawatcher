import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thread-safe local SQLite storage for per-app hourly network usage history.
public final class UsageDatabase: @unchecked Sendable {
    public let databaseURL: URL?

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.datawatcher.sqlite", qos: .utility)

    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Datawatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.sqlite")
    }

    public init(path: String? = nil) throws {
        let resolvedPath: String
        if let path {
            resolvedPath = path
            if path == ":memory:" {
                self.databaseURL = nil
            } else {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                self.databaseURL = url
            }
        } else {
            let url = Self.defaultDatabaseURL()
            self.databaseURL = url
            resolvedPath = url.path
        }

        var handle: OpaquePointer?
        if sqlite3_open_v2(
            resolvedPath,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.openFailed(message)
        }
        self.db = handle

        try queue.sync {
            try self.configureAndMigrate()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public enum DatabaseError: Error, LocalizedError {
        case openFailed(String)
        case statementFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "SQLite open failed: \(msg)"
            case .statementFailed(let msg): return "SQLite statement failed: \(msg)"
            }
        }
    }

    private func configureAndMigrate() throws {
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")

        try execute("""
            CREATE TABLE IF NOT EXISTS apps (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                bundle_id TEXT,
                app_path TEXT,
                is_system INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );
            """)

        try execute("""
            CREATE TABLE IF NOT EXISTS usage_hourly (
                bucket_ts INTEGER NOT NULL,
                app_id TEXT NOT NULL,
                bytes_in INTEGER NOT NULL,
                bytes_out INTEGER NOT NULL,
                PRIMARY KEY (bucket_ts, app_id)
            );
            """)

        try execute("CREATE INDEX IF NOT EXISTS idx_usage_hourly_ts ON usage_hourly(bucket_ts);")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_hourly_app_ts ON usage_hourly(app_id, bucket_ts);")
    }

    /// Truncates a `Date` to the start of its UTC hour in epoch seconds.
    public static func hourBucketTimestamp(for date: Date) -> Int64 {
        let secs = Int64(floor(date.timeIntervalSince1970))
        return (secs / 3600) * 3600
    }

    /// Persists a batch of `(app, bytesIn, bytesOut)` deltas into the hourly bucket for `date`.
    public func recordBatch(_ entries: [(app: AppRecord, bytesIn: Int64, bytesOut: Int64)], at date: Date = Date()) {
        let nonZero = entries.filter { $0.bytesIn > 0 || $0.bytesOut > 0 }
        guard !nonZero.isEmpty else { return }

        let bucketTs = Self.hourBucketTimestamp(for: date)
        let nowTs = Int64(date.timeIntervalSince1970)

        queue.sync {
            guard let db else { return }
            do {
                try execute("BEGIN IMMEDIATE TRANSACTION;")

                let upsertAppSQL = """
                    INSERT INTO apps (id, name, bundle_id, app_path, is_system, updated_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        bundle_id = COALESCE(excluded.bundle_id, apps.bundle_id),
                        app_path = COALESCE(excluded.app_path, apps.app_path),
                        is_system = excluded.is_system,
                        updated_at = excluded.updated_at;
                    """

                let upsertUsageSQL = """
                    INSERT INTO usage_hourly (bucket_ts, app_id, bytes_in, bytes_out)
                    VALUES (?1, ?2, ?3, ?4)
                    ON CONFLICT(bucket_ts, app_id) DO UPDATE SET
                        bytes_in = bytes_in + excluded.bytes_in,
                        bytes_out = bytes_out + excluded.bytes_out;
                    """

                var appStmt: OpaquePointer?
                var usageStmt: OpaquePointer?
                defer {
                    if let appStmt { sqlite3_finalize(appStmt) }
                    if let usageStmt { sqlite3_finalize(usageStmt) }
                }

                guard sqlite3_prepare_v2(db, upsertAppSQL, -1, &appStmt, nil) == SQLITE_OK,
                      sqlite3_prepare_v2(db, upsertUsageSQL, -1, &usageStmt, nil) == SQLITE_OK else {
                    try? execute("ROLLBACK;")
                    return
                }

                for item in nonZero {
                    sqlite3_reset(appStmt)
                    sqlite3_clear_bindings(appStmt)
                    bindText(appStmt, index: 1, value: item.app.id)
                    bindText(appStmt, index: 2, value: item.app.name)
                    bindOptionalText(appStmt, index: 3, value: item.app.bundleId)
                    bindOptionalText(appStmt, index: 4, value: item.app.appPath)
                    sqlite3_bind_int(appStmt, 5, item.app.isSystem ? 1 : 0)
                    sqlite3_bind_int64(appStmt, 6, nowTs)
                    sqlite3_step(appStmt)

                    sqlite3_reset(usageStmt)
                    sqlite3_clear_bindings(usageStmt)
                    sqlite3_bind_int64(usageStmt, 1, bucketTs)
                    bindText(usageStmt, index: 2, value: item.app.id)
                    sqlite3_bind_int64(usageStmt, 3, item.bytesIn)
                    sqlite3_bind_int64(usageStmt, 4, item.bytesOut)
                    sqlite3_step(usageStmt)
                }

                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
            }
        }
    }

    /// Fetches per-app aggregated download/upload totals within `[from, to]`.
    public func fetchAppSummaries(from: Date?, to: Date?, includeSystem: Bool) -> [AppUsageSummary] {
        queue.sync {
            guard let db else { return [] }

            var conditions: [String] = []
            if from != nil { conditions.append("u.bucket_ts >= ?") }
            if to != nil { conditions.append("u.bucket_ts <= ?") }
            if !includeSystem { conditions.append("a.is_system = 0") }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT a.id, a.name, a.bundle_id, a.app_path, a.is_system,
                       SUM(u.bytes_in) AS total_in, SUM(u.bytes_out) AS total_out
                FROM usage_hourly u
                INNER JOIN apps a ON a.id = u.app_id
                \(whereClause)
                GROUP BY a.id
                ORDER BY (total_in + total_out) DESC;
                """

            var stmt: OpaquePointer?
            defer { if let stmt { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var bindIdx: Int32 = 1
            if let from {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: from))
                bindIdx += 1
            }
            if let to {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: to))
                bindIdx += 1
            }

            var results: [AppUsageSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = columnText(stmt, index: 0) ?? ""
                let name = columnText(stmt, index: 1) ?? id
                let bundleId = columnText(stmt, index: 2)
                let appPath = columnText(stmt, index: 3)
                let isSystem = sqlite3_column_int(stmt, 4) != 0
                let bytesIn = sqlite3_column_int64(stmt, 5)
                let bytesOut = sqlite3_column_int64(stmt, 6)

                let app = AppRecord(
                    id: id,
                    name: name,
                    bundleId: bundleId,
                    appPath: appPath,
                    isSystem: isSystem
                )
                results.append(AppUsageSummary(app: app, bytesIn: bytesIn, bytesOut: bytesOut))
            }
            return results
        }
    }

    /// Fetches historical time-series buckets aggregated by `granularity` in `calendar` local time,
    /// filling zero-value buckets across the active interval for clean charts.
    public func fetchTimeSeries(
        from: Date?,
        to: Date?,
        appId: String?,
        granularity: ChartGranularity,
        includeSystem: Bool,
        calendar: Calendar = .current
    ) -> [TimeBucketPoint] {
        let rawRows: [(ts: Int64, bytesIn: Int64, bytesOut: Int64)] = queue.sync {
            guard let db else { return [] }

            var conditions: [String] = []
            if from != nil { conditions.append("u.bucket_ts >= ?") }
            if to != nil { conditions.append("u.bucket_ts <= ?") }
            if appId != nil { conditions.append("u.app_id = ?") }
            if !includeSystem && appId == nil { conditions.append("a.is_system = 0") }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT u.bucket_ts, SUM(u.bytes_in), SUM(u.bytes_out)
                FROM usage_hourly u
                INNER JOIN apps a ON a.id = u.app_id
                \(whereClause)
                GROUP BY u.bucket_ts
                ORDER BY u.bucket_ts ASC;
                """

            var stmt: OpaquePointer?
            defer { if let stmt { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var bindIdx: Int32 = 1
            if let from {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: from))
                bindIdx += 1
            }
            if let to {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: to))
                bindIdx += 1
            }
            if let appId {
                bindText(stmt, index: bindIdx, value: appId)
                bindIdx += 1
            }

            var rows: [(Int64, Int64, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((
                    sqlite3_column_int64(stmt, 0),
                    sqlite3_column_int64(stmt, 1),
                    sqlite3_column_int64(stmt, 2)
                ))
            }
            return rows
        }

        var grouped: [Date: (inBytes: Int64, outBytes: Int64)] = [:]
        for row in rawRows {
            let date = Date(timeIntervalSince1970: TimeInterval(row.ts))
            let bucketDate = Self.bucketStart(for: date, granularity: granularity, calendar: calendar)
            let existing = grouped[bucketDate] ?? (0, 0)
            grouped[bucketDate] = (existing.inBytes + row.bytesIn, existing.outBytes + row.bytesOut)
        }

        let startRef: Date?
        let endRef: Date?
        if let from, let to {
            startRef = from
            endRef = to
        } else if let minKey = grouped.keys.min(), let maxKey = grouped.keys.max() {
            startRef = from ?? minKey
            endRef = to ?? maxKey
        } else {
            return []
        }

        guard let startRef, let endRef, startRef <= endRef else {
            return grouped.keys.sorted().map { key in
                let val = grouped[key] ?? (0, 0)
                return TimeBucketPoint(date: key, bytesIn: val.inBytes, bytesOut: val.outBytes)
            }
        }

        let firstBucket = Self.bucketStart(for: startRef, granularity: granularity, calendar: calendar)
        let lastBucket = Self.bucketStart(for: endRef, granularity: granularity, calendar: calendar)

        var points: [TimeBucketPoint] = []
        var cursor = firstBucket
        var safetyCounter = 0
        let maxPoints = 500

        while cursor <= lastBucket && safetyCounter < maxPoints {
            let val = grouped[cursor] ?? (0, 0)
            points.append(TimeBucketPoint(date: cursor, bytesIn: val.inBytes, bytesOut: val.outBytes))
            guard let next = Self.advanceBucket(cursor, granularity: granularity, calendar: calendar),
                  next > cursor else {
                break
            }
            cursor = next
            safetyCounter += 1
        }

        return points
    }

    /// Returns aggregate `(bytesIn, bytesOut)` within `[from, to]` optionally filtered by `appId`.
    public func fetchTotals(from: Date?, to: Date?, appId: String?, includeSystem: Bool) -> (bytesIn: Int64, bytesOut: Int64) {
        queue.sync {
            guard let db else { return (0, 0) }

            var conditions: [String] = []
            if from != nil { conditions.append("u.bucket_ts >= ?") }
            if to != nil { conditions.append("u.bucket_ts <= ?") }
            if appId != nil { conditions.append("u.app_id = ?") }
            if !includeSystem && appId == nil { conditions.append("a.is_system = 0") }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT COALESCE(SUM(u.bytes_in), 0), COALESCE(SUM(u.bytes_out), 0)
                FROM usage_hourly u
                INNER JOIN apps a ON a.id = u.app_id
                \(whereClause);
                """

            var stmt: OpaquePointer?
            defer { if let stmt { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }

            var bindIdx: Int32 = 1
            if let from {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: from))
                bindIdx += 1
            }
            if let to {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: to))
                bindIdx += 1
            }
            if let appId {
                bindText(stmt, index: bindIdx, value: appId)
                bindIdx += 1
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
            }
            return (0, 0)
        }
    }

    /// Exports filtered hourly usage records as a CSV string.
    public func exportCSV(from: Date?, to: Date?, appId: String?, includeSystem: Bool) -> String {
        queue.sync {
            guard let db else { return "" }

            var conditions: [String] = []
            if from != nil { conditions.append("u.bucket_ts >= ?") }
            if to != nil { conditions.append("u.bucket_ts <= ?") }
            if appId != nil { conditions.append("u.app_id = ?") }
            if !includeSystem && appId == nil { conditions.append("a.is_system = 0") }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT u.bucket_ts, a.id, a.name, COALESCE(a.bundle_id, ''), a.is_system, u.bytes_in, u.bytes_out
                FROM usage_hourly u
                INNER JOIN apps a ON a.id = u.app_id
                \(whereClause)
                ORDER BY u.bucket_ts ASC, (u.bytes_in + u.bytes_out) DESC;
                """

            var stmt: OpaquePointer?
            defer { if let stmt { sqlite3_finalize(stmt) } }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }

            var bindIdx: Int32 = 1
            if let from {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: from))
                bindIdx += 1
            }
            if let to {
                sqlite3_bind_int64(stmt, bindIdx, Self.hourBucketTimestamp(for: to))
                bindIdx += 1
            }
            if let appId {
                bindText(stmt, index: bindIdx, value: appId)
                bindIdx += 1
            }

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]

            var lines = ["timestamp_iso,app_id,app_name,bundle_id,is_system,bytes_in,bytes_out,total_bytes"]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_int64(stmt, 0)
                let iso = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
                let id = csvEscape(columnText(stmt, index: 1) ?? "")
                let name = csvEscape(columnText(stmt, index: 2) ?? "")
                let bundleId = csvEscape(columnText(stmt, index: 3) ?? "")
                let isSys = sqlite3_column_int(stmt, 4) != 0 ? "true" : "false"
                let bytesIn = sqlite3_column_int64(stmt, 5)
                let bytesOut = sqlite3_column_int64(stmt, 6)
                let total = bytesIn + bytesOut
                lines.append("\(iso),\(id),\(name),\(bundleId),\(isSys),\(bytesIn),\(bytesOut),\(total)")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Removes all stored traffic and app history.
    public func clearAllData() {
        queue.sync {
            try? execute("DELETE FROM usage_hourly;")
            try? execute("DELETE FROM apps;")
            try? execute("VACUUM;")
        }
    }

    /// Returns the total disk footprint of the SQLite database (including WAL/SHM files).
    public func databaseFileSizeBytes() -> Int64 {
        guard let url = databaseURL else { return 0 }
        let fm = FileManager.default
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        var total: Int64 = 0
        for p in paths {
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: - Helpers

    private static func bucketStart(for date: Date, granularity: ChartGranularity, calendar: Calendar) -> Date {
        switch granularity {
        case .hour:
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: comps) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: comps) ?? date
        }
    }

    private static func advanceBucket(_ date: Date, granularity: ChartGranularity, calendar: Calendar) -> Date? {
        switch granularity {
        case .hour: return calendar.date(byAdding: .hour, value: 1, to: date)
        case .day: return calendar.date(byAdding: .day, value: 1, to: date)
        case .week: return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .month: return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw DatabaseError.statementFailed(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
