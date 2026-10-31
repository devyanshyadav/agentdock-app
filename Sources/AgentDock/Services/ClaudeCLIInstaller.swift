import Foundation

/// User-initiated native install using Anthropic's official latest channel, without sudo.
enum ClaudeCLIInstaller {
    static func install() async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentdock-claude-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = try await AgentCommand.run(executable: "/usr/bin/curl", arguments: [
            "--proto", "=https", "--proto-redir", "=https", "--fail", "--silent", "--show-error", "--location",
            "--connect-timeout", "15", "--max-time", "60", "https://claude.ai/install.sh"
        ], timeout: 65) { try $0.readAll() }
        guard let text = String(data: script, encoding: .utf8), text.hasPrefix("#!") else {
            throw IntegrationError.message("Anthropic’s installer could not be downloaded. Try again or use the installation guide.")
        }
        let path = directory.appendingPathComponent("install.sh")
        try script.write(to: path, options: .atomic)
        try await AgentCommand.run(executable: "/bin/bash", arguments: [path.path, "latest"], timeout: 300,
            environment: ["BASH_ENV": "/dev/null"]) { session in
            _ = try session.readAll()
        }

        guard let executable = AgentCommandEnvironment.executable("claude") else {
            throw IntegrationError.message("The installer finished, but the Claude CLI wasn’t found. Check Anthropic’s installation guide.")
        }
        let version = try await AgentCommand.run(executable: executable, arguments: ["--version"], timeout: 15) { session in
            String(decoding: try session.readAll(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !version.isEmpty, version.utf8.count <= 256 else {
            throw IntegrationError.message("Claude Code installed, but its version could not be verified.")
        }
        return version
    }
}
