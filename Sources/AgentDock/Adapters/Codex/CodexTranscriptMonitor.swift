import Foundation

/// A read-only compatibility fallback. Hook events remain the authority for approvals.
struct CodexTranscriptEvent: Sendable {
    let sessionID: String
    let turnID: String?
    let date: Date
    let status: AgentStatus
    let text: String
    let model: String
    let surface: AgentEnvironment
    let startsTurn: Bool
    // Source metadata, independent of display wording or localization.
    var hasDetail = true
}

struct CodexTranscriptDecoder: Sendable {
    let sessionID: String
    let surface: AgentEnvironment
    var model = ""
    var turnID: String?
    init?(metadata: [String: Any]) {
        guard let id = metadata["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              !(metadata["source"] is [String: Any]) else { return nil }
        sessionID = id
        let originator = (metadata["originator"] as? String ?? "").lowercased()
        surface = metadata["source"] as? String == "cli" || originator.contains("cli") ? .cli : .dedicatedWindow
    }

    mutating func decode(_ line: String) -> CodexTranscriptEvent? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return nil }
        let type = record["type"] as? String
        if type == "turn_context" {
            if let value = payload["model"] as? String { model = String(value.prefix(256)) }
            turnID = payload["turn_id"] as? String ?? turnID
            return nil
        }
        let eventType = payload["type"] as? String
        let status: AgentStatus
        let text: String
        var startsTurn = false
        var hasDetail = false
        let eventTurn = payload["turn_id"] as? String ?? turnID
        if type == "event_msg" {
            switch eventType {
            case "task_started", "turn_started":
                status = .working; text = "Working…"; startsTurn = true
            case "task_complete", "turn_complete": status = .completed; text = "Response complete"
            case "turn_aborted": status = .idle; text = ""
            case "item_started", "item_completed":
                guard let item = payload["item"] as? [String: Any], let activity = Self.itemActivity(item) else { return nil }
                status = .working; text = activity; hasDetail = true
            case "agent_reasoning":
                let detail = Self.preview(payload["text"] as? String)
                status = .working; text = detail ?? "Thinking…"; hasDetail = detail != nil
            case "agent_message":
                status = .working
                let detail = payload["phase"] as? String == "commentary" ? Self.preview(payload["message"] as? String) : nil
                text = detail ?? "Writing a response…"; hasDetail = detail != nil
            default: return nil
            }
        } else if type == "response_item" {
            switch eventType {
            case "function_call", "custom_tool_call":
                status = .working; text = Self.toolDescription(payload)
                hasDetail = Self.preview(payload["name"] as? String) != nil
            case "reasoning":
                let detail = Self.summary(payload["summary"])
                status = .working; text = detail ?? "Thinking…"; hasDetail = detail != nil
            case "message" where payload["role"] as? String == "assistant":
                status = .working
                let detail = payload["phase"] as? String == "commentary" ? Self.summary(payload["content"]) : nil
                text = detail ?? "Writing a response…"; hasDetail = detail != nil
            default: return nil
            }
        } else { return nil }
        guard let timestamp = record["timestamp"] as? String,
              let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
                ?? (try? Date.ISO8601FormatStyle().parse(timestamp)) else { return nil }
        if startsTurn { turnID = eventTurn }
        return CodexTranscriptEvent(sessionID: sessionID, turnID: eventTurn, date: date, status: status,
                                    text: text, model: model, surface: surface, startsTurn: startsTurn, hasDetail: hasDetail)
    }
    private static func itemActivity(_ item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "CommandExecution":
            let commands = item["parsed_cmd"] as? [[String: Any]] ?? []
            for command in commands {
                if command["type"] as? String == "read", let name = preview(command["name"] as? String) {
                    return String(("Read " + name).prefix(220))
                }
                if command["type"] as? String == "search", let query = preview(command["query"] as? String) {
                    return String(("Searched for " + query).prefix(220))
                }
            }
            if let command = item["command"] as? [String], let text = preview(command.last) { return String(("Ran " + text).prefix(220)) }
            return "Running a command…"
        case "Extension" where item["kind"] as? String == "web.search":
            let action = item["action"] as? [String: Any] ?? [:]
            if action["type"] as? String == "search" {
                let queries = action["queries"] as? [String] ?? []
                let query = preview(action["query"] as? String ?? item["query"] as? String ?? queries.first)
                return query.map { String(("Searching the web for " + $0).prefix(220)) } ?? "Searching the web…"
            }
            if action["type"] as? String == "openPage" { return "Opening a web page…" }
            return nil
        case "McpToolCall":
            return activityDescription(name: item["tool"] as? String ?? "MCP tool", input: item["arguments"] as? [String: Any] ?? [:])
        case "Reasoning":
            return (item["summary_text"] as? [String])?.lazy.compactMap { preview($0) }.first
        case "AgentMessage" where item["phase"] as? String == "commentary":
            return summary(item["content"])
        default: return nil
        }
    }
    private static func preview(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = String(value.prefix(512)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(220))
    }

    /// Only explicitly exposed text is used. Encrypted/raw reasoning is never read.
    private static func summary(_ value: Any?) -> String? {
        guard let items = value as? [[String: Any]] else { return nil }
        return items.lazy.filter { ["summary_text", "output_text", "text", "Text"].contains($0["type"] as? String ?? "") }
            .compactMap { preview($0["text"] as? String) }.first
    }

    static func activityDescription(name: String, input: [String: Any]) -> String {
        let name = preview(name) ?? "Using a tool…"
        if let description = preview(input["description"] as? String) { return description }
        if let path = input["file_path"] as? String ?? input["path"] as? String,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let file = preview(URL(fileURLWithPath: path).lastPathComponent) { return String((name + ": " + file).prefix(220)) }
        if let query = preview(input["query"] as? String) { return String((name + ": " + query).prefix(220)) }
        let command = input["command"] as? String ?? input["cmd"] as? String
        if let command = preview(command) { return String((name + ": " + command).prefix(220)) }
        if let command = input["command"] as? [String], let text = preview(command.joined(separator: " ")) {
            return String((name + ": " + text).prefix(220))
        }
        return name
    }
    private static func toolDescription(_ payload: [String: Any]) -> String {
        let name = preview(payload["name"] as? String) ?? "Using a tool…"
        let arguments = payload["arguments"] as? String ?? payload["input"] as? String
        guard let arguments, arguments.utf8.count <= 16 * 1024 else { return name }
        if let data = arguments.data(using: .utf8),
           let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return activityDescription(name: name, input: input)
        }
        if name == "apply_patch" {
            let files = arguments.split(separator: "\n").filter {
                $0.hasPrefix("*** Update File: ") || $0.hasPrefix("*** Add File: ") || $0.hasPrefix("*** Delete File: ")
            }.prefix(3).compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let path = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return preview(URL(fileURLWithPath: path).lastPathComponent)
            }
            if !files.isEmpty { return String(("Editing " + files.joined(separator: ", ")).prefix(220)) }
        }
        return name
    }
}

/// Metadata and the initial tail are read off the main actor. Subsequent appends use
/// the shared bounded JSONL tailer, starting at the exact last complete line read here.
struct CodexTranscriptSnapshot: Sendable {
    let decoder: CodexTranscriptDecoder
    let events: [CodexTranscriptEvent]
    let offset: UInt64
    var usage: SessionUsage? = nil

    static func load(path: String, root: String, startedAt: Date) -> Self? {
        guard TranscriptSupport.isAllowed(path, under: [root]),
              (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var header = Data()
        while header.count < 2 * 1024 * 1024 {
            guard let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty else { break }
            header.append(chunk)
            if chunk.contains(0x0A) { break }
        }
        guard let newline = header.firstIndex(of: 0x0A),
              let metadata = try? JSONSerialization.jsonObject(with: header[..<newline]) as? [String: Any],
              metadata["type"] as? String == "session_meta",
              let payload = metadata["payload"] as? [String: Any],
              var decoder = CodexTranscriptDecoder(metadata: payload),
              let size = try? handle.seekToEnd() else { return nil }
        let start = size - min(size, 256 * 1024)
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let lastNewline = data.lastIndex(of: 0x0A) else { return nil }
        var lines = data[...lastNewline].split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let events = lines.compactMap { decoder.decode(String(decoding: $0, as: UTF8.self)) }
        var live = events.filter { $0.date >= startedAt }
        // Reconstruct only a recent in-progress turn, never historical completion banners.
        if let previous = events.last(where: { $0.date < startedAt }), previous.status.isLive,
           Date().timeIntervalSince(previous.date) < 120,
           live.first?.startsTurn != true {
            live.insert(CodexTranscriptEvent(sessionID: previous.sessionID, turnID: previous.turnID,
                date: previous.date, status: .working, text: previous.text, model: decoder.model,
                surface: previous.surface, startsTurn: true, hasDetail: previous.hasDetail), at: 0)
        }
        let usage = lines.compactMap { UsageParsers.codexLine(String(decoding: $0, as: UTF8.self), sessionID: decoder.sessionID) }
            .max { $0.updatedAt < $1.updatedAt }
        return Self(decoder: decoder, events: live, offset: start + UInt64(lastNewline) + 1, usage: usage)
    }

    static func discover(root: String) -> [String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [(String, Date)] = []
        // Startup discovery is bounded. Files outside this window are attached on their next write.
        for case let url as URL in enumerator.prefix(10_000) where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append((url.path, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(64).map(\.0)
    }
}

@MainActor
final class CodexTranscriptMonitor {
    private struct Entry {
        var decoder: CodexTranscriptDecoder
        let watcher: LogStreamWatcher
        var updated = Date()
        var live = false
    }
    private let root: String
    private let onEvent: (CodexTranscriptEvent) -> Void
    private let onUsage: (SessionUsage) -> Void
    private var observer: FileChangeObserver?
    private var entries: [String: Entry] = [:]
    private var pending = Set<String>()
    private var reading: Task<Void, Never>?
    private var discovery: Task<Void, Never>?
    private var startedAt = Date()

    init(root: String, onEvent: @escaping (CodexTranscriptEvent) -> Void, onUsage: @escaping (SessionUsage) -> Void = { _ in }) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        self.onEvent = onEvent
        self.onUsage = onUsage
    }
    func start() {
        guard observer == nil else { return }
        startedAt = Date()
        observer = FileChangeObserver(paths: [root], onFileChange: { [weak self] path in
            self?.enqueue(path)
        }, onChange: { [weak self] in self?.discover() })
        observer?.start(); discover()
    }
    func stop() {
        observer?.stop(); observer = nil
        discovery?.cancel(); discovery = nil; reading?.cancel(); reading = nil
        entries.values.forEach { $0.watcher.stop() }; entries.removeAll(); pending.removeAll()
    }
    private func discover() {
        guard discovery == nil, observer != nil else { return }
        let root = root
        discovery = Task { [weak self] in
            // Directory traversal is blocking IO; keep it away from UI/file-event callbacks.
            let paths = await Task.detached(priority: .utility) { CodexTranscriptSnapshot.discover(root: root) }.value
            guard !Task.isCancelled, let self else { return }
            self.discovery = nil
            for path in paths { self.enqueue(path) }
        }
    }
    private func enqueue(_ path: String) {
        guard observer != nil, path.hasSuffix(".jsonl"), entries[path] == nil, pending.count < 128 else { return }
        pending.insert(path)
        guard reading == nil else { return }
        reading = Task { [weak self] in
            while !Task.isCancelled, let self, let path = self.pending.popFirst() {
                if self.entries[path] != nil { continue }
                let root = self.root, started = self.startedAt
                let snapshot = await Task.detached(priority: .utility) {
                    CodexTranscriptSnapshot.load(path: path, root: root, startedAt: started)
                }.value
                guard !Task.isCancelled else { return }
                if let snapshot { self.attach(path, snapshot: snapshot) }
            }
            if !Task.isCancelled { self?.reading = nil }
        }
    }
    private func attach(_ path: String, snapshot: CodexTranscriptSnapshot) {
        guard observer != nil, entries[path] == nil else { return }
        if entries.count >= 64 {
            guard let oldest = entries.filter({ !$0.value.live }).min(by: { $0.value.updated < $1.value.updated })?.key else { return }
            entries.removeValue(forKey: oldest)?.watcher.stop()
        }
        let watcher = LogStreamWatcher(observesDirectory: false, initialReadOffset: snapshot.offset,
            discoverActiveFile: { (path, Date(), nil) }, onLine: { [weak self] line, _ in
                guard let self, let decoder = self.entries[path]?.decoder else { return }
                if let usage = UsageParsers.codexLine(line, sessionID: decoder.sessionID) { self.onUsage(usage) }
                guard let event = self.entries[path]?.decoder.decode(line) else { return }
                self.entries[path]?.updated = Date(); self.entries[path]?.live = event.status.isLive
                self.onEvent(event)
            })
        entries[path] = Entry(decoder: snapshot.decoder, watcher: watcher)
        if let usage = snapshot.usage { onUsage(usage) }
        for event in snapshot.events { entries[path]?.live = event.status.isLive; onEvent(event) }
        watcher.start()
    }
}
