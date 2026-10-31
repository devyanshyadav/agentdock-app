import Foundation
import Testing
@testable import AgentDock

struct HookTimeoutTests {
    @Test(arguments: [AgentKind.claude, .codex])
    func updatingRequestBudgetPreservesOtherObservers(provider: AgentKind) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.sh")
        let destination = root.appendingPathComponent("Observer's hooks/observer.sh")
        let config = root.appendingPathComponent(provider == .claude ? "settings.json" : "hooks.json")
        let command = "'" + destination.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let foreign: [String: Any] = ["type": "command", "command": "another-tool", "timeout": 1]
        let owned: [String: Any] = ["type": "command", "command": command, "timeout": 1]
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: source)
        let existing: [String: Any] = [
            "PreToolUse": [["matcher": "*", "hooks": [foreign, owned]]],
            "SessionEnd": [["hooks": [["type": "command", "command": command, "timeout": 4]]]]
        ]
        try JSONSerialization.data(withJSONObject: ["unrelated": true, "hooks": existing]).write(to: config)
        func install() throws {
            if provider == .claude { try ClaudeHookInstaller.install(base: root, destination: destination, source: source) }
            else { try CodexHookInstaller.install(base: root, destination: destination, source: source) }
        }
        try install()
        let data = try Data(contentsOf: config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(json["hooks"] as? [String: [[String: Any]]])
        let pre = try #require(events["PreToolUse"]?.first?["hooks"] as? [[String: Any]])
        #expect(json["unrelated"] as? Bool == true)
        #expect(pre.count == 2)
        #expect(NSDictionary(dictionary: pre[0]).isEqual(to: foreign))
        #expect(pre[1]["timeout"] as? Int == 2)
        for event in (provider == .codex ? ["SessionEnd", "Interrupt"] : ["SessionEnd"]) {
            let groups = try #require(events[event])
            let hooks = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            #expect(hooks.filter { $0["command"] as? String == command }.count == 1)
        }
        for groups in events.values {
            let hooks = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            #expect(hooks.filter { $0["command"] as? String == command }.allSatisfy { $0["timeout"] as? Int == 2 })
        }
        try install()
        #expect(try Data(contentsOf: config) == data)
    }
}
