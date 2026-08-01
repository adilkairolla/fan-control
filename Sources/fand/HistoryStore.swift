import Foundation
import SQLite3
import FanKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Rolling metric history in SQLite. Small, append-only, pruned on a schedule.
final class HistoryStore {

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let retention: TimeInterval

    init(path: String, retention: TimeInterval = 7 * 24 * 3600) throws {
        self.retention = retention

        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory,
                                                 withIntermediateDirectories: true)

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "HistoryStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "sqlite3_open failed: \(message)"])
        }

        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS samples (
                ts        REAL PRIMARY KEY,
                fan_rpm   TEXT NOT NULL,
                cpu_c     REAL NOT NULL,
                gpu_c     REAL NOT NULL,
                hotspot_c REAL NOT NULL,
                cpu_busy  REAL NOT NULL,
                mem_used  REAL NOT NULL
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func insert(_ sample: HistorySample) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }

        let sql = """
            INSERT OR REPLACE INTO samples
            (ts, fan_rpm, cpu_c, gpu_c, hotspot_c, cpu_busy, mem_used)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let rpmJSON = (try? JSONEncoder().encode(sample.fanRPM))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_double(stmt, 1, sample.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, rpmJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, sample.cpuCelsius)
        sqlite3_bind_double(stmt, 4, sample.gpuCelsius)
        sqlite3_bind_double(stmt, 5, sample.hotspotCelsius)
        sqlite3_bind_double(stmt, 6, sample.cpuBusy)
        sqlite3_bind_double(stmt, 7, sample.memoryUsedFraction)

        sqlite3_step(stmt)
    }

    func query(since: Date, limit: Int = 20_000) -> [HistorySample] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }

        let sql = "SELECT ts, fan_rpm, cpu_c, gpu_c, hotspot_c, cpu_busy, mem_used "
                + "FROM samples WHERE ts >= ? ORDER BY ts ASC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [HistorySample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt, 0)
            let rpmText = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "[]"
            let rpm = (rpmText.data(using: .utf8))
                .flatMap { try? JSONDecoder().decode([Double].self, from: $0) } ?? []

            out.append(HistorySample(
                timestamp: Date(timeIntervalSince1970: ts),
                fanRPM: rpm,
                cpuCelsius: sqlite3_column_double(stmt, 2),
                gpuCelsius: sqlite3_column_double(stmt, 3),
                hotspotCelsius: sqlite3_column_double(stmt, 4),
                cpuBusy: sqlite3_column_double(stmt, 5),
                memoryUsedFraction: sqlite3_column_double(stmt, 6)
            ))
        }
        return out
    }

    func prune() {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        let cutoff = Date().addingTimeInterval(-retention).timeIntervalSince1970

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM samples WHERE ts < ?;", -1, &stmt, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }
}
