import Foundation

/// Read explicit runtime lifecycle events from every Cursor window. No tool/permission guesses.
@MainActor
final class CursorLogWatcher {
    static let shared = CursorLogWatcher()
    private var watchers: [String: LogStreamWatcher] = [:]
    private var discoveryObserver: FileChangeObserver?
    private init() {}
    func start() {
        guard discoveryObserver == nil else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/logs")
        discoveryObserver = FileChangeObserver(paths: [root.path]) { [weak self] in self?.discover() }
        discoveryObserver?.start()
        discover()
    }
    func stop() {
        discoveryObserver?.stop(); discoveryObserver = nil
        watchers.values.forEach { $0.stop() }; watchers.removeAll()
    }

    static func consume(_ line: String) {
        guard let event = CursorRuntimeEvent.decode(line) else { return }
        CursorAgentAdapter.shared.consumeRuntime(event)
    }
    private func discover() {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/logs")
        guard let session = (try? fm.contentsOfDirectory(atPath: root.path))?.filter({ !$0.hasPrefix(".") }).max() else { return }
        let directory = root.appendingPathComponent(session)
        let paths = Set(((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("window") }
            .map { directory.appendingPathComponent($0).appendingPathComponent("renderer.log").path }
            .filter { fm.fileExists(atPath: $0) })
        for path in Array(watchers.keys) where !paths.contains(path) { watchers.removeValue(forKey: path)?.stop() }
        for path in paths where watchers[path] == nil {
            let watcher = LogStreamWatcher(observesDirectory: false, discoverActiveFile: {
                let date = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (path, date, nil)
            }, onLine: { line, _ in Self.consume(line) })
            watchers[path] = watcher
            watcher.start()
        }
    }

}

struct CursorRuntimeEvent {
    let conversationID: String
    let status: AgentStatus
    let date: Date
    static func decode(_ line: String) -> Self? {
        guard line.contains("[ComposerWakelockManager]"),
              let idRange = line.range(of: "composerId="),
              let id = line[idRange.upperBound...].split(whereSeparator: { $0.isWhitespace }).first,
              !id.isEmpty else { return nil }
        let status: AgentStatus
        if line.contains("Released wakelock"), line.contains("reason=\"user-approval-requested\"") { status = .waitingApproval }
        else if line.contains("Released wakelock"), line.contains("reason=\"generation-ended\"") { status = .completed }
        else if line.contains("Released wakelock") { status = .idle }
        else if line.contains("Acquired wakelock"), line.contains("reason=\"agent-loop\"") || line.contains("reason=\"agent-loop-resumed\"") { status = .working }
        else { return nil }
        guard let date = dateFormatter.date(from: String(line.prefix(23))) else { return nil }
        return Self(conversationID: String(id), status: status, date: date)
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
