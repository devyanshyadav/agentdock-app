import Foundation

/// OpenCode discovers local plugins itself; no edits to its JSON/JSONC settings are needed.
enum OpenCodeIntegration {
    static var plugin: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("opencode/plugins/agentdock.js")
    }
    static var source: URL? { Bundle.main.resourceURL?.appendingPathComponent("OpenCodeHooks/agentdock.js") }

    static func install(destination: URL = plugin, source: URL? = source) throws {
        guard let source else { throw IntegrationError.message("The OpenCode observer is missing.") }
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) == data { return }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: destination, to: destination.appendingPathExtension("agentdock-backup-" + UUID().uuidString))
        }
        try data.write(to: destination, options: .atomic)
    }
    static func installation() -> ProviderIntegration.Installation {
        guard FileManager.default.fileExists(atPath: plugin.path) else { return .missing }
        guard let actual = try? Data(contentsOf: plugin), let source, let expected = try? Data(contentsOf: source) else { return .repair }
        return actual == expected ? .configured : .updateAvailable
    }
}
