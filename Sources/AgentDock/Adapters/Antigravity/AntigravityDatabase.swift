import Foundation
import SQLite3

/// Read-only snapshots of Antigravity's own session records. Called on a utility task.
/// Missing files, unknown schemas, contention and read errors return nil and preserve UI state.
enum AntigravityDatabase {
    struct RunState: Equatable, Sendable {
        let status: String
        let notFullyIdle: Bool
        let killed: Bool
        let modifiedAt: Date?
        var isIdleOrCancelled: Bool {
            killed || status == "CASCADE_RUN_STATUS_CANCELING"
                || status == "CASCADE_RUN_STATUS_IDLE" && !notFullyIdle
        }
    }
    struct StepState: Equatable, Sendable {
        let waitingApprovals: [Int: String]
        let activeActivity: String?
    }

    static func readRuns(path: String, sessionIDs: [String]) -> [String: RunState]? {
        guard !sessionIDs.isEmpty else { return [:] }
        return snapshot(path) { db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            let sql = "SELECT conversation_id, status, not_fully_idle, killed, (julianday(last_modified_time) - 2440587.5) * 86400 FROM conversation_summaries WHERE conversation_id IN (\(placeholders))"
            var states: [String: RunState] = [:]
            guard rows(db, sql: sql, bindings: sessionIDs, consume: { row in
                guard let id = text(row, 0), let status = text(row, 1) else { return }
                let date = sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 4))
                states[id] = RunState(status: status, notFullyIdle: sqlite3_column_int(row, 2) != 0,
                                      killed: sqlite3_column_int(row, 3) != 0, modifiedAt: date)
            }) else { return nil }
            return states
        }
    }

    static func readSteps(path: String, sinceStep: Int? = nil) -> StepState? {
        snapshot(path) { db in
            var waiting: [Int: String] = [:]
            guard rows(db, sql: "SELECT idx, metadata FROM steps WHERE status = 9", consume: { row in
                waiting[Int(sqlite3_column_int(row, 0))] = AntigravityStepDecoder.permission(metadata: blob(row, 1))
            }) else { return nil }
            // All pending requests are retained. Only the latest relevant activity needs decoding.
            var activity: String?
            // Completed planner text is eligible only when the hook supplies its step boundary.
            let completed = sinceStep.map { " OR (step_type = 15 AND status = 3 AND idx >= \(max(0, $0)))" } ?? ""
            let sql = "SELECT step_type, metadata, step_payload FROM steps WHERE status IN (2, 8)\(completed) ORDER BY idx DESC LIMIT 1"
            guard rows(db, sql: sql, consume: { row in
                activity = AntigravityStepDecoder.activity(metadata: blob(row, 1), payload: blob(row, 2),
                                                           stepType: Int(sqlite3_column_int(row, 0)))
            }) else { return nil }
            return StepState(waitingApprovals: waiting, activeActivity: activity)
        }
    }

    private static func snapshot<T>(_ path: String, read: (OpaquePointer) -> T?) -> T? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 200)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        return read(database)
    }

    private static func rows(_ db: OpaquePointer, sql: String, bindings: [String] = [], consume: (OpaquePointer) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { return false }
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            consume(statement)
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE
    }
    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }
    private static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, count <= 256 * 1024, let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
