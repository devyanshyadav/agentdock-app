import Foundation
import Testing
@testable import AgentDock

struct AgentPortabilityTests {
    @Test @MainActor func detectsAgentCLIsWithoutLaunchingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("Custom agent tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("agent-was-launched")
        let agents: [(AgentKind, String)] = [(.claude, "claude"), (.codex, "codex"),
                                            (.cursor, "cursor-agent"), (.antigravity, "agy"),
                                            (.opencode, "opencode")]
        for (kind, command) in agents {
            let executable = bin.appendingPathComponent(command)
            try Data("#!/bin/sh\nprintf invoked > '\(marker.path)'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            #expect(ProviderIntegration(kind: kind).isDetected(environment: ["PATH": bin.path], home: root))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func discoversCustomInstallationsWithoutExecutingAShell() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let bin = root.appendingPathComponent("Custom tools 'quoted'/bin")
        let home = root.appendingPathComponent("Home")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("agentdock-test-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = ["PATH": ":relative-bin:\(bin.path):\(bin.path)"]
        #expect(AgentCommandEnvironment.executable("agentdock-test-cli", environment: environment, home: home) == executable.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        #expect(AgentCommandEnvironment.executable("agentdock-test-cli", environment: environment, home: home) == nil)
        let paths = AgentCommandEnvironment.searchDirectories(environment: environment, home: home)
        #expect(paths.first == bin.path)
        #expect(Set(paths).count == paths.count)
        #expect(paths.allSatisfy { $0.hasPrefix("/") })
        let npmBin = home.appendingPathComponent(".npm-global/bin")
        try fm.createDirectory(at: npmBin, withIntermediateDirectories: true)
        let npmCLI = npmBin.appendingPathComponent("agentdock-test-cli")
        try fm.copyItem(at: executable, to: npmCLI)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: npmCLI.path)
        #expect(AgentCommandEnvironment.executable("agentdock-test-cli", environment: [:], home: home) == npmCLI.path)
        try fm.removeItem(at: executable)
        try fm.createDirectory(at: executable, withIntermediateDirectories: true)
        #expect(AgentCommandEnvironment.executable("agentdock-test-cli", environment: ["PATH": bin.path], home: root) == nil)
    }

    @Test func transcriptTailIsBoundedAndRejectsEscapingPaths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        try Data((String(repeating: "historical-data\n", count: 1000) + "latest\n").utf8).write(to: file)
        #expect(TranscriptSupport.tailLines(of: file.path, maxBytes: 20) == ["latest"])
        #expect(TranscriptSupport.tailLines(of: file.path, maxBytes: 0).isEmpty)
        #expect(TranscriptSupport.isAllowed(file.path, under: [root.path]))
        let directory = root.appendingPathComponent("directory.jsonl")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(!TranscriptSupport.isAllowed(directory.path, under: [root.path]))
        let link = root.appendingPathComponent("escape.jsonl")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        #expect(!TranscriptSupport.isAllowed(link.path, under: [root.path]))
        #expect(!TranscriptSupport.isAllowed(file.path, under: [root.appendingPathComponent("other").path]))
    }
    @Test @MainActor func fixedTranscriptWatcherRecoversAfterReplacement() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        try Data("old record\n".utf8).write(to: file)
        var lines: [String] = []
        let watcher = LogStreamWatcher(observesDirectory: false,
            discoverActiveFile: { (file.path, Date(), nil) }, onLine: { line, _ in lines.append(line) })
        watcher.start()
        defer { watcher.stop() }
        try fm.moveItem(at: file, to: root.appendingPathComponent("old.jsonl"))
        try await Task.sleep(nanoseconds: 150_000_000)
        try Data("replacement record\n".utf8).write(to: file)
        for _ in 0..<40 {
            if lines.contains("replacement record") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(lines == ["replacement record"])
        watcher.stop()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("after stop\n".utf8))
        try handle.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(lines == ["replacement record"])
    }

    @Test func notchWindowFrameAlwaysSticksToScreenTopEdgeRegardlessOfPhysicalNotch() {
        let externalScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let visibleWithMenuBarAndDock = CGRect(x: 0, y: 70, width: 2560, height: 1345)
        let nonNotchGeometry = NotchGeometry(screenFrame: externalScreen, visibleFrame: visibleWithMenuBarAndDock)
        let nonNotchFrame = nonNotchGeometry.notchWindowFrame()
        #expect(nonNotchFrame.maxY == externalScreen.maxY)
        #expect(nonNotchFrame.midX == externalScreen.midX)

        let laptopScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let laptopVisible = CGRect(x: 0, y: 0, width: 1512, height: 948)
        let notchGeometry = NotchGeometry(screenFrame: laptopScreen, visibleFrame: laptopVisible,
                                          topLeftArea: CGRect(x: 0, y: 948, width: 660, height: 34),
                                          topRightArea: CGRect(x: 852, y: 948, width: 660, height: 34),
                                          safeAreaTop: 34)
        let notchFrame = notchGeometry.notchWindowFrame()
        #expect(notchFrame.maxY == laptopScreen.maxY)
        #expect(notchFrame.midX == laptopScreen.midX)
    }

}
