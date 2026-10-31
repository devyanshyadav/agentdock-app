import Foundation
import Network
import os

/// Loopback-only HTTP bridge for scripts and hooks to push agent status.
public final class LocalServerBridge {
    public static let shared = LocalServerBridge()
    private static let logger = Logger(subsystem: "com.siliconapps.agentdock", category: "Bridge")

    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 1 * 1024 * 1024
    private static let maxConnections = 32
    private static let receiveTimeoutSeconds: TimeInterval = 5

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.agentdock.localserver", qos: .userInitiated)
    // Listener and connection state are confined to queue.
    private var connections: [ObjectIdentifier: ConnectionState] = [:]

    public struct StatusPayload: Codable {
        public let agent: String?
        public let status: String?
        public let action: String?
        public let message: String?
        public let detail: String?
        public let model: String?
        public let mode: String?
        public let sessionID: String?
    }

    private final class ConnectionState {
        var buffer = Data()
        let connection: NWConnection
        var responding = false
        var deadline: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private init() {}

    private var endpointFile: URL?
    private var listeningPort: UInt16?
    private let bridgeToken = UUID().uuidString
    private var bridgeTokenFile: URL?

    public func start(port: UInt16 = 49152, publishEndpoint: Bool = true) {
        queue.async { self.listen(port: port, attemptsRemaining: 10, publishEndpoint: publishEndpoint) }
    }

    private func listen(port: UInt16, attemptsRemaining: Int, publishEndpoint: Bool) {
        listener?.cancel()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let next = try NWListener(using: parameters)
            listener = next
            next.stateUpdateHandler = { [weak self, weak next] state in
                guard let self, let next, self.listener === next else { return }
                switch state {
                case .ready:
                    self.listeningPort = port
                    if publishEndpoint { self.publishPort(port) }
                    Task { @MainActor in
                        AgentStateManager.shared.localBridgePort = Int(port)
                        AgentStateManager.shared.isLocalBridgeListening = true
                    }
                case .failed(let error):
                    if case .posix(.EADDRINUSE) = error, attemptsRemaining > 0, port < UInt16.max {
                        self.listen(port: port + 1, attemptsRemaining: attemptsRemaining - 1, publishEndpoint: publishEndpoint)
                    } else {
                        Task { @MainActor in AgentStateManager.shared.isLocalBridgeListening = false }
                        Self.logger.error("Local bridge failed: \(String(describing: error))")
                    }
                default: break
                }
            }
            next.newConnectionHandler = { [weak self] connection in self?.acceptConnection(connection) }
            next.start(queue: queue)
        } catch { Self.logger.error("Failed to start listener: \(String(describing: error))") }
    }

    private func publishPort(_ port: UInt16) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dockDirectory = home.appendingPathComponent("Library/Application Support/AgentDock")
        let file = dockDirectory.appendingPathComponent("bridge-port")
        do {
            try FileManager.default.createDirectory(at: dockDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(String(port).utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            endpointFile = file
            let tokenFile = dockDirectory.appendingPathComponent("bridge-token")
            try Data(bridgeToken.utf8).write(to: tokenFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            bridgeTokenFile = tokenFile
        } catch { Self.logger.error("Could not publish bridge endpoint: \(String(describing: error))") }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            for state in Array(self.connections.values) { self.finish(state.connection) }
            if let file = self.endpointFile, let port = self.listeningPort,
               (try? String(contentsOf: file, encoding: .utf8)) == String(port) { try? FileManager.default.removeItem(at: file) }
            if let file = self.bridgeTokenFile,
               (try? String(contentsOf: file, encoding: .utf8)) == self.bridgeToken {
                try? FileManager.default.removeItem(at: file)
            }
            self.bridgeTokenFile = nil
            self.endpointFile = nil; self.listeningPort = nil
        }
        Task { @MainActor in AgentStateManager.shared.isLocalBridgeListening = false }
    }

    private func acceptConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard connections.count < Self.maxConnections else {
            let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
            return
        }
        let state = ConnectionState(connection)
        connections[ObjectIdentifier(connection)] = state
        connection.stateUpdateHandler = { [weak self] status in
            if case .failed = status { self?.finish(connection) }
            if case .cancelled = status { self?.finish(connection) }
        }
        let deadline = DispatchWorkItem { [weak self] in
            self?.sendResponse(connection: connection, statusCode: 408, body: "{\"error\":\"timeout\"}")
        }
        state.deadline = deadline
        queue.asyncAfter(deadline: .now() + Self.receiveTimeoutSeconds, execute: deadline)
        receive(from: connection, state: state)
    }

    private func finish(_ connection: NWConnection) {
        guard let state = connections.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        state.deadline?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive(from connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, self.connections[ObjectIdentifier(connection)] === state, !state.responding else { return }
            if let content { state.buffer.append(content) }
            if state.buffer.count > Self.maxHeaderBytes + Self.maxBodyBytes {
                self.sendResponse(connection: connection, statusCode: 413, body: "{\"error\":\"payload_too_large\"}"); return
            }
            switch self.parseRequest(from: state.buffer) {
            case .ready(let request): self.handleRequest(request, connection: connection); return
            case .reject(let body): self.sendResponse(connection: connection, statusCode: 400, body: body); return
            case .incomplete: break
            }
            if error != nil || isComplete {
                self.finish(connection)
            } else { self.receive(from: connection, state: state) }
        }
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let body: Data
        /// Agent process reported by CLI observers; used only for liveness checks.
        var ownerPID: Int32? = nil
        /// Per-launch shared secret read by observers from the app's support directory.
        var token: String? = nil
    }

    private enum ParseOutcome {
        case incomplete
        case ready(ParsedRequest)
        case reject(String)
    }

    private func parseRequest(from buffer: Data) -> ParseOutcome {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderBytes {
                return .reject("{\"error\":\"header_too_large\"}")
            }
            return .incomplete
        }

        guard headerEnd.upperBound <= Self.maxHeaderBytes else { return .reject("{\"error\":\"header_too_large\"}") }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .reject("{\"error\":\"bad_request\"}") }
        let lines = headerString.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])) else { return .reject("{\"error\":\"bad_request\"}") }
        let method = String(parts[0])
        let path = String(parts[1])
        var contentLength: Int?
        var ownerPID: Int32?
        var token: String?
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { return .reject("{\"error\":\"bad_header\"}") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else { return .reject("{\"error\":\"bad_header\"}") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "origin" || name == "sec-fetch-site" { return .ready(ParsedRequest(method: "REJECT", path: "", body: Data())) }
            if name == "x-agentdock-ppid" {
                if let pid = Int32(value), pid > 1, pid < 4_194_304 { ownerPID = ProcessLineage.agentProcess(startingAt: pid) }
                continue
            }
            if name == "x-agentdock-token" { token = value; continue }
            if name == "transfer-encoding" { return .reject("{\"error\":\"unsupported_transfer_encoding\"}") }
            if name == "content-length" {
                guard contentLength == nil, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let length = Int(value), length <= Self.maxBodyBytes else { return .reject("{\"error\":\"invalid_content_length\"}") }
                contentLength = length
            }
        }
        let bodySlice = buffer[headerEnd.upperBound...]
        if method == "GET" || method == "OPTIONS" {
            guard (contentLength ?? 0) == 0, bodySlice.isEmpty else { return .reject("{\"error\":\"bad_request\"}") }
            return .ready(ParsedRequest(method: method, path: path, body: Data(), ownerPID: ownerPID, token: token))
        }
        guard let contentLength else { return .reject("{\"error\":\"content_length_required\"}") }
        guard bodySlice.count <= contentLength else { return .reject("{\"error\":\"unexpected_body_bytes\"}") }
        guard bodySlice.count == contentLength else { return .incomplete }
        return .ready(ParsedRequest(method: method, path: path, body: Data(bodySlice), ownerPID: ownerPID, token: token))
    }

    private func handleRequest(_ request: ParsedRequest, connection: NWConnection) {
        if request.method == "REJECT" {
            sendResponse(connection: connection, statusCode: 403, body: "{\"error\":\"browser_request_rejected\"}")
            return
        }

        let method = request.method
        let path = request.path

        if method == "OPTIONS" {
            sendResponse(connection: connection, statusCode: 204, body: "")
            return
        }

        if path == "/health" && method == "GET" {
            sendResponse(connection: connection, statusCode: 200, body: "{\"status\":\"ok\",\"app\":\"AgentDock\"}")
            return
        }

        // Everything below reads or changes agent state. Only processes that can read the app's
        // private support directory (observers, the user's own scripts) know the secret.
        guard request.token == bridgeToken else {
            sendResponse(connection: connection, statusCode: 403, body: "{\"error\":\"unauthorized\"}")
            return
        }

        if path == "/claude-usage" && method == "POST" {
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendResponse(connection: connection, statusCode: 400, body: "{}")
                return
            }
            onMainActor {
                let accepted = UsageStore.shared.consumeClaude(json)
                self.sendResponse(connection: connection, statusCode: accepted ? 200 : 400, body: "{}")
            }
            return
        }

        if path == "/status" && method == "GET" {
            onMainActor {
                let s = AgentStateManager.shared
                let dict: [String: Any] = [
                    "agent": s.activeAgent.displayName,
                    "status": s.status.rawValue,
                    "action": s.currentAction.rawValue,
                    "message": s.message,
                    "detail": s.detail ?? "",
                    "model": s.modelName

                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    self.sendResponse(connection: connection, statusCode: 200, body: jsonStr)
                } else {
                    self.sendResponse(connection: connection, statusCode: 200, body: "{}")
                }
            }
            return
        }

        if path == "/reset" && method == "POST" {
            onMainActor {
                AgentStateManager.shared.reset()
                self.sendResponse(connection: connection, statusCode: 200, body: "{\"status\":\"reset\"}")
            }
            return
        }

        if path == "/opencode-event" && method == "POST" {
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendResponse(connection: connection, statusCode: 400, body: "{}")
                return
            }
            let ownerPID = request.ownerPID
            onMainActor {
                let accepted = OpenCodeAgentAdapter.shared.consume(json, ownerPID: ownerPID)
                self.sendResponse(connection: connection, statusCode: accepted ? 200 : 400, body: "{}")
            }
            return
        }

        if path.hasPrefix("/antigravity-event/") && method == "POST" {
            guard var json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_antigravity_event\"}")
                return
            }
            json["event"] = String(path.dropFirst("/antigravity-event/".count))
            if let pid = request.ownerPID {
                json["_agentdock_pid"] = Int(pid)
            }
            let event = json
            onMainActor {
                switch AntigravityAgentAdapter.shared.consumeHook(event) {
                case .accepted:
                    self.sendResponse(connection: connection, statusCode: 200, body: "{}")
                case .invalid:
                    self.sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_antigravity_event\"}")
                case .capacityExceeded:
                    self.sendResponse(connection: connection, statusCode: 503, body: "{\"error\":\"antigravity_session_capacity\"}")
                }
            }
            return
        }

        if (path == "/codex-event" || path == "/codex-event/cli" || path == "/codex-event/desktop") && method == "POST" {
            guard var json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_codex_event\"}")
                return
            }
            let surface = path.hasSuffix("/cli") ? "cli" : "desktop"
            json["_agentdock_surface"] = surface
            if let pid = request.ownerPID {
                json["_agentdock_pid"] = Int(pid)
            }
            let event = json
            onMainActor {
                switch CodexAgentAdapter.shared.consumeHook(event) {
                case .accepted: self.sendResponse(connection: connection, statusCode: 200, body: "{}")
                case .invalid: self.sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_codex_event\"}")
                case .capacityExceeded: self.sendResponse(connection: connection, statusCode: 503, body: "{\"error\":\"codex_session_capacity\"}")
                }
            }
            return
        }

        if (path == "/claude-event" || path == "/claude-event/cli" || path == "/claude-event/ide" || path == "/claude-event/desktop") && method == "POST" {
            guard var json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_claude_event\"}")
                return
            }
            let surface = path.hasSuffix("/cli") ? "cli" : path.hasSuffix("/ide") ? "ide" : "desktop"
            json["_agentdock_surface"] = surface
            if let pid = request.ownerPID {
                json["_agentdock_pid"] = Int(pid)
            }
            let event = json
            onMainActor {
                switch ClaudeCodeAdapter.shared.consumeHook(event) {
                case .accepted: self.sendResponse(connection: connection, statusCode: 200, body: "{}")
                case .invalid: self.sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_claude_event\"}")
                case .capacityExceeded: self.sendResponse(connection: connection, statusCode: 503, body: "{\"error\":\"claude_session_capacity\"}")
                }
            }
            return
        }

        if ["/cursor-event", "/cursor-event/cli", "/cursor-event/ide"].contains(path) && method == "POST" {
            guard var json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_cursor_event\"}")
                return
            }
            let surface = path.hasSuffix("/cli") ? "cli" : "ide"
            json["_agentdock_surface"] = surface
            if let pid = request.ownerPID {
                json["_agentdock_pid"] = Int(pid)
            }
            let event = json
            onMainActor {
                let accepted = CursorAgentAdapter.shared.consumeHook(event)
                self.sendResponse(connection: connection, statusCode: accepted ? 200 : 400,
                                  body: accepted ? "{}" : "{\"error\":\"invalid_cursor_event\"}")
            }
            return
        }

        if path == "/status" && method == "POST" {
            do {
                let payload = try JSONDecoder().decode(StatusPayload.self, from: request.body)
                onMainActor {
                    self.dispatchPayload(payload)
                    self.sendResponse(connection: connection, statusCode: 200, body: "{\"status\":\"updated\"}")
                }
            } catch {
                sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid_json\"}")
            }
            return
        }

        sendResponse(connection: connection, statusCode: 404, body: "{\"error\":\"not_found\"}")
    }

    /// Agent state belongs to the main actor; HTTP authentication is checked before dispatch.
    private func onMainActor(_ operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in operation() }
    }

    @MainActor
    private func dispatchPayload(_ payload: StatusPayload) {
        let agentKind = AgentKind(rawValue: payload.agent?.lowercased() ?? "cursor") ?? .generic
        let status = AgentStatus(rawValue: payload.status?.lowercased() ?? "working") ?? .working
        let message = payload.message ?? ""
        let model = payload.model

        AgentStateManager.shared.update(
            agent: agentKind,
            status: status,
            message: message,
            model: model,
            sessionID: payload.sessionID.map { "http:" + $0 } ?? "http:default",
            startsTurn: status.isLive
        )
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        // Callers may be on MainActor after preparing a status snapshot.
        queue.async { [self] in
            guard let state = self.connections[ObjectIdentifier(connection)], !state.responding else { return }
            state.responding = true
            state.deadline?.cancel()
            let cleanup = DispatchWorkItem { [weak self] in self?.finish(connection) }
            state.deadline = cleanup
            self.queue.asyncAfter(deadline: .now() + 1, execute: cleanup)
            let text = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 408: "Request Timeout", 413: "Payload Too Large", 503: "Service Unavailable"][statusCode] ?? "Error"
            let response = "HTTP/1.1 \(statusCode) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.finish(connection) }
            })
        }
    }
}
