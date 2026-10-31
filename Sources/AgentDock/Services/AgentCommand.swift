import Darwin
import Foundation

/// Bounded, cancellable process transport with argument arrays, not interpolated shell commands.
enum AgentCommand {
    static func run<Value: Sendable>(executable: String, arguments: [String], timeout: TimeInterval = 8,
        environment: [String: String] = [:], body: @escaping @Sendable (Session) throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let session = try Session(executable: executable, arguments: arguments, timeout: timeout, environment: environment)
            defer { session.close() }
            return try body(session)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// Confined to the worker task; poll bounds reads even if a descendant inherits stdout.
    final class Session {
        private let process = Process()
        private let input = Pipe(), output = Pipe()
        private let deadline: TimeInterval
        private var buffer = Data()
        private var received = 0
        private static let outputLimit = 2_097_152

        init(executable: String, arguments: [String], timeout: TimeInterval, environment: [String: String]) throws {
            deadline = ProcessInfo.processInfo.systemUptime + timeout
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var variables = ProcessInfo.processInfo.environment
            variables["PATH"] = AgentCommandEnvironment.searchDirectories().joined(separator: ":")
            variables.merge(environment) { _, new in new }
            process.environment = variables
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let writer = input.fileHandleForWriting.fileDescriptor
            guard fcntl(writer, F_SETNOSIGPIPE, 1) != -1,
                  fcntl(writer, F_SETFL, O_NONBLOCK) != -1,
                  fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
                throw IntegrationError.message("Couldn’t prepare the CLI command pipes.")
            }
            try process.run()
            // Only the child owns these ends after launch.
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }

        func close() {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        private func wait(_ descriptor: Int32, for events: Int16) throws {
            while true {
                try Task.checkCancellation()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw IntegrationError.message("The CLI command timed out.") }
                var item = pollfd(fd: descriptor, events: events, revents: 0)
                let result = poll(&item, 1, Int32(min(remaining * 1000 + 1, 100)))
                if result > 0 { return }
                if result < 0, errno != EINTR { throw IntegrationError.message("The CLI command pipe failed.") }
            }
        }

        func writeLine(_ line: String) throws {
            let data = Data((line + "\n").utf8)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(input.fileHandleForWriting.fileDescriptor, for: Int16(POLLOUT))
                    let count = Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0, errno != EAGAIN, errno != EINTR {
                        throw IntegrationError.message("The CLI command closed its input.")
                    }
                }
            }
        }

        private func readChunk() throws -> Data? {
            let descriptor = output.fileHandleForReading.fileDescriptor
            while true {
                try wait(descriptor, for: Int16(POLLIN))
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count == 0 { return nil }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw IntegrationError.message("Couldn’t read the CLI command output.")
                }
                received += count
                guard received <= Self.outputLimit else { throw IntegrationError.message("CLI command output exceeded its limit.") }
                return Data(bytes.prefix(count))
            }
        }

        func readLine() throws -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    return line
                }
                guard let chunk = try readChunk() else {
                    guard !buffer.isEmpty else { return nil }
                    defer { buffer.removeAll() }
                    return buffer
                }
                buffer.append(chunk)
            }
        }

        func readAll() throws -> Data {
            try? input.fileHandleForWriting.close()
            var data = Data()
            while let chunk = try readChunk() { data.append(chunk) }
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw IntegrationError.message("The CLI command timed out.") }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw IntegrationError.message("The CLI command failed. Check the CLI version and sign-in.") }
            return data
        }
    }
}
