import Foundation

/// Small, bounded helpers for reading provider transcripts. Transcripts are an
/// on-disk record the providers already write; we only ever read them.
enum TranscriptSupport {
    /// Reads at most `maxBytes` from the end of a file, aligned to a line start.
    static func tailLines(of path: String, maxBytes: Int = 256 * 1024) -> [String] {
        guard maxBytes > 0, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readData(ofLength: maxBytes)
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // First line is probably truncated.
        return lines
    }

    /// Whether `path` is a regular `.jsonl` file below one of the allowed directories.
    /// The bridge is local IPC, so hook-supplied paths are never trusted blindly.
    static func isAllowed(_ path: String, under roots: [String]) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension == "jsonl",
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
        let resolved = url.path
        return roots.contains { root in
            let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            return resolved.hasPrefix(base + "/")
        }
    }
}
