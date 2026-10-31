import Darwin
import Foundation

/// Finds the agent process behind a hook invocation using libproc, so observer scripts
/// only need to pass `$PPID` and never spawn `ps` on the hot path.
enum ProcessLineage {
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "nu", "tcsh", "csh", "ksh"]

    /// Walks up from `pid` to the first ancestor that is neither a shell nor an app bundle
    /// process (GUI apps such as editors outlive any agent turn, so they prove nothing).
    static func agentProcess(startingAt pid: Int32, maxDepth: Int = 5) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let path = path(of: current) else { return nil }
            let name = (path as NSString).lastPathComponent
            if !shells.contains(name) && !name.hasPrefix("-") {
                return path.contains(".app/") ? nil : current
            }
            guard let parent = parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    private static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }
}
