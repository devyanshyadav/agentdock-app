import Foundation
import CoreServices

/// Event-driven JSONL tailer. Native file notifications handle writes and rotation;
/// directory events attach newly created files without recurring scans.
@MainActor
public final class LogStreamWatcher {
    private let fileManager = FileManager.default
    private var directoryObserver: FileChangeObserver?
    private var running = false
    private var fileOffsetsByPath: [String: UInt64] = [:]
    private var pendingLineByPath: [String: Data] = [:]
    private var identities: [String: UInt64] = [:]
    private var discardingLine = Set<String>()
    private var currentPath: String?
    private var startedAt = Date.distantPast
    private var fileSource: DispatchSourceFileSystemObject?
    private let watchDirectories: [String]
    public let maxStartupTrailingBytes: UInt64
    private let observesDirectory: Bool
    private let initialReadOffset: UInt64?

    private let discoverActiveFile: () -> (path: String?, modDate: Date, id: String?)
    private let onLine: (String, String) -> Void

    public init(
        watchDirectories: [String] = [],
        maxStartupTrailingBytes: UInt64 = 32768,
        observesDirectory: Bool = true,
        initialReadOffset: UInt64? = nil,
        discoverActiveFile: @escaping () -> (path: String?, modDate: Date, id: String?),
        onLine: @escaping (String, String) -> Void
    ) {
        self.watchDirectories = watchDirectories
        self.maxStartupTrailingBytes = maxStartupTrailingBytes
        self.observesDirectory = observesDirectory
        self.initialReadOffset = initialReadOffset
        self.discoverActiveFile = discoverActiveFile
        self.onLine = onLine
    }

    public func start() {
        guard !running else { return }
        running = true
        startedAt = Date()
        let initial = discoverActiveFile()
        // A fixed file normally needs no directory stream, but until it exists the directory is the
        // only way to learn of its creation; the stream is dropped once the file is attached.
        let fileExists = initial.path.map { fileManager.fileExists(atPath: $0) } ?? false
        let directories = !observesDirectory && fileExists ? [] : watchDirectories.isEmpty
            ? initial.path.map { [URL(fileURLWithPath: $0).deletingLastPathComponent().path] } ?? []
            : watchDirectories
        observeDirectories(directories)
        attachDiscoveredFile(initial: true)
    }

    private func observeDirectories(_ directories: [String]) {
        guard directoryObserver == nil, !directories.isEmpty else { return }
        directoryObserver = FileChangeObserver(paths: directories) { [weak self] in
            guard let self, self.running else { return }
            self.attachDiscoveredFile(initial: false)
            self.readAvailable()
        }
        directoryObserver?.start()
    }

    public func stop() {
        running = false
        directoryObserver?.stop(); directoryObserver = nil
        fileSource?.cancel(); fileSource = nil
        currentPath = nil
    }

    private func armFileSource(path: String) {
        fileSource?.cancel()
        fileSource = nil

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.running, self.fileSource === source else { return }
            if !source.data.intersection([.delete, .rename]).isEmpty {
                self.fileSource?.cancel(); self.fileSource = nil
                // A fixed transcript can be replaced after its old vnode disappears.
                // Observe its parent only until the replacement has been attached.
                self.observeDirectories([URL(fileURLWithPath: path).deletingLastPathComponent().path])
                self.attachDiscoveredFile(initial: false)
            }
            self.readAvailable()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
        if !observesDirectory { directoryObserver?.stop(); directoryObserver = nil }
    }

    private func attachDiscoveredFile(initial: Bool) {
        let (pathOpt, modifiedAt, _) = discoverActiveFile()
        guard let path = pathOpt else { return }

        let identity = fileIdentity(path: path)
        let replaced = identities[path] != nil && identities[path] != identity
        if replaced {
            fileOffsetsByPath[path] = 0
            pendingLineByPath[path] = Data()
            discardingLine.remove(path)
        }
        if identities.count >= 128, identities[path] == nil {
            for obsolete in identities.keys.sorted() where obsolete != currentPath && identities.count >= 128 {
                identities[obsolete] = nil; fileOffsetsByPath[obsolete] = nil
                pendingLineByPath[obsolete] = nil; discardingLine.remove(obsolete)
            }
        }
        identities[path] = identity
        if path != currentPath || initial || replaced || fileSource == nil {
            currentPath = path
            armFileSource(path: path)

            if let savedOffset = fileOffsetsByPath[path] {
                readAndParse(from: savedOffset, path: path)
            } else if let size = fileSize(path: path) {
                if initial, let initialReadOffset {
                    let offset = initialReadOffset <= size ? initialReadOffset : 0
                    fileOffsetsByPath[path] = offset
                    readAndParse(from: offset, path: path)
                } else if initial || modifiedAt <= startedAt {
                    // Discovery may finish asynchronously. Old files are historical even when found after startup.
                    fileOffsetsByPath[path] = size
                    pendingLineByPath[path] = Data()
                } else {
                    let rawOffset = max(0, size - min(size, maxStartupTrailingBytes))
                    let alignedOffset = alignToNextNewline(offset: rawOffset, path: path)
                    fileOffsetsByPath[path] = alignedOffset
                    readAndParse(from: alignedOffset, path: path)
                }
            }
        }
    }

    private func readAvailable() {
        guard let path = currentPath, let size = fileSize(path: path) else { return }
        let identity = fileIdentity(path: path)
        if identities[path] != identity {
            identities[path] = identity
            fileOffsetsByPath[path] = 0
            pendingLineByPath[path] = Data()
            discardingLine.remove(path)
            armFileSource(path: path)
        }
        let currentOffset = fileOffsetsByPath[path] ?? 0

        if size < currentOffset {
            fileOffsetsByPath[path] = 0
            pendingLineByPath[path] = Data()
            discardingLine.remove(path)
        }

        if size > (fileOffsetsByPath[path] ?? 0) {
            readAndParse(from: fileOffsetsByPath[path] ?? 0, path: path)
        }
    }

    /// File I/O, UTF-8 decoding and line splitting run on a utility queue so a burst of log output
    /// never occupies the main thread. Only the finished lines are delivered back to it.
    private struct Chunk {
        var consumed: UInt64
        var lines: [String]
        var pending: Data
        var discarding: Bool
        var hasMore: Bool
    }
    private enum Limit {
        static let line = 2 * 1024 * 1024
        static let batch = 256 * 1024
    }
    private static let ioQueue = DispatchQueue(label: "agentdock.logstream", qos: .utility)
    private var readingPaths = Set<String>()
    private var rereadPaths = Set<String>()

    private func readAndParse(from offset: UInt64, path: String) {
        // One read per file at a time; events that arrive meanwhile are folded into a follow-up read.
        guard readingPaths.insert(path).inserted else { rereadPaths.insert(path); return }
        let pending = pendingLineByPath[path] ?? Data()
        let discarding = discardingLine.contains(path)
        Self.ioQueue.async { [weak self] in
            let chunk = Self.readChunk(path: path, offset: offset, pending: pending, discarding: discarding)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRead(chunk, from: offset, path: path) } }
        }
    }

    private func finishRead(_ chunk: Chunk?, from offset: UInt64, path: String) {
        readingPaths.remove(path)
        let again = rereadPaths.remove(path) != nil
        guard running else { return }
        // A rotation or reset while the read was in flight makes its result stale.
        if let chunk, (fileOffsetsByPath[path] ?? 0) == offset {
            fileOffsetsByPath[path] = offset + chunk.consumed
            pendingLineByPath[path] = chunk.pending
            if chunk.discarding { discardingLine.insert(path) } else { discardingLine.remove(path) }
            for line in chunk.lines { onLine(line, path) }
            if chunk.hasMore, currentPath == path { readAvailable(); return }
        }
        if again, currentPath == path { readAvailable() }
    }

    nonisolated private static func readChunk(path: String, offset: UInt64, pending: Data, discarding: Bool) -> Chunk? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: offset)) != nil else { return nil }
        // Keep each batch bounded even when a transcript grows rapidly.
        let data = handle.readData(ofLength: Limit.batch)
        guard !data.isEmpty else { return nil }
        var pending = pending, discarding = discarding
        var lines: [String] = []
        var cursor = data.startIndex
        // Slice on newline boundaries instead of appending byte by byte.
        while cursor < data.endIndex {
            let newline = data[cursor...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            if !discarding {
                pending.append(data[cursor..<end])
                if pending.count > Limit.line { pending.removeAll(keepingCapacity: false); discarding = true }
            }
            guard let newline else { break }
            if !discarding, !pending.isEmpty, let line = String(data: pending, encoding: .utf8) { lines.append(line) }
            pending.removeAll(keepingCapacity: true)
            discarding = false
            cursor = newline + 1
        }
        let consumed = UInt64(data.count)
        return Chunk(consumed: consumed, lines: lines, pending: pending, discarding: discarding,
                     hasMore: size > offset + consumed)
    }

    private func fileIdentity(path: String) -> UInt64? {
        (try? fileManager.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64
    }

    private func fileSize(path: String) -> UInt64? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return nil }
        return size
    }

    private func alignToNextNewline(offset: UInt64, path: String) -> UInt64 {
        if offset == 0 { return 0 }
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? fileHandle.close() }

        try? fileHandle.seek(toOffset: offset)
        let sampleData = fileHandle.readData(ofLength: 4096)
        if let idx = sampleData.firstIndex(of: UInt8(ascii: "\n")) {
            return offset + UInt64(idx) + 1
        }
        return offset
    }
}

/// Structural filesystem events replace directory-discovery timers. The nearest
/// existing parent also observes provider directories created after app launch.
@MainActor
final class FileChangeObserver {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: () -> Void
    private let onFileChange: ((String) -> Void)?

    init(paths: [String], onFileChange: ((String) -> Void)? = nil, onChange: @escaping () -> Void) {
        self.paths = paths.map(Self.canonicalPath)
        self.onChange = onChange
        self.onFileChange = onFileChange
    }

    private static func canonicalPath(_ path: String) -> String {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            missing.append(directory.lastPathComponent)
            directory.deleteLastPathComponent()
        }
        guard let resolved = realpath(directory.path, nil) else { return path }
        defer { free(resolved) }
        let root = String(cString: resolved)
        return missing.isEmpty ? root : (root == "/" ? "" : root) + "/" + missing.reversed().joined(separator: "/")
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        let roots = Set(paths.map { path in
            var directory = URL(fileURLWithPath: path)
            while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
                directory.deleteLastPathComponent()
            }
            return directory.path
        })
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let observer = Unmanaged<FileChangeObserver>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            MainActor.assumeIsolated {
                let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs)
                let writes = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod)
                let relevant = structural | (observer.onFileChange == nil ? 0 : writes)
                var needsDiscovery = false
                for index in 0..<count where flags[index] & relevant != 0 {
                    let path = changed[index]
                    guard observer.paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { continue }
                    observer.onFileChange?(path)
                    if flags[index] & structural != 0 { needsDiscovery = true }
                }
                if needsDiscovery { observer.onChange() }
            }
        }, &context, Array(roots) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { stop() }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
    }
}
