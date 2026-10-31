import Foundation

/// Shared CLI discovery and child-process PATH for apps launched from Finder or a shell.
/// No shell startup scripts are executed, and relative PATH entries never select workspace code.
enum AgentCommandEnvironment {
    static func searchDirectories(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let defaults = [".local/bin", ".cursor/bin", ".npm-global/bin", ".bun/bin", ".opencode/bin"].map {
            home.appendingPathComponent($0).path
        } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return (inherited + defaults).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func executable(_ name: String,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        searchDirectories(environment: environment, home: home).lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
            }
    }

}
