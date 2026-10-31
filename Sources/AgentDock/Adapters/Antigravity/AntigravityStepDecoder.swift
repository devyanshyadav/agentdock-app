import Foundation

/// Field numbers belong to Antigravity's StepMetadata, ToolCall and PlannerResponse messages.
/// Decode only public activity fields; never search arbitrary binary data for JSON or text.
enum AntigravityStepDecoder {
    static func activity(metadata: Data, payload: Data, stepType: Int) -> String? {
        if let call = Message(metadata)?.first(4), let tool = tool(call) {
            return AntigravityActivityEvent.toolText(tool)
        }
        guard stepType == 15, let planner = Message(payload)?.first(20), let message = Message(planner) else { return nil }
        if let call = message.fields[7]?.last, let tool = tool(call) {
            return AntigravityActivityEvent.toolText(tool)
        }
        if let thinking = message.text(3) { return AntigravityActivityEvent.preview("Thought: " + thinking) }
        if let response = message.text(1) ?? message.text(8) {
            return AntigravityActivityEvent.preview("Response: " + response)
        }
        return nil
    }

    static func permission(metadata: Data) -> String {
        guard let call = Message(metadata)?.first(4), let tool = tool(call) else { return "Permission: Approval required" }
        if let request = AntigravityActivityEvent.requestText(tool) { return request }
        let text = AntigravityActivityEvent.toolText(tool)
        let detail = text.firstIndex(of: ":").map { String(text[text.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? text
        return AntigravityActivityEvent.preview("Permission: " + detail)
    }

    private static func tool(_ data: Data) -> [String: Any]? {
        guard let message = Message(data), let name = message.text(2), name.utf8.count <= 256,
              let encoded = message.first(3),
              let args = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return nil }
        return ["name": name, "args": args]
    }

    /// Bounded protobuf wire reader. Unknown scalar fields are skipped and malformed records
    /// fail closed, rather than returning fields from a partially decoded message.
    private struct Message {
        var fields: [Int: [Data]] = [:]
        init?(_ data: Data) {
            guard data.count <= 256 * 1024 else { return nil }
            let bytes = [UInt8](data)
            var offset = 0
            func varint() -> UInt64? {
                var value: UInt64 = 0
                for shift in stride(from: 0, through: 63, by: 7) {
                    guard offset < bytes.count else { return nil }
                    let byte = bytes[offset]; offset += 1
                    guard shift != 63 || byte <= 1 else { return nil }
                    value |= UInt64(byte & 0x7f) << shift
                    if byte & 0x80 == 0 { return value }
                }
                return nil
            }
            while offset < bytes.count {
                guard let tag = varint(), tag >> 3 > 0 else { return nil }
                switch tag & 7 {
                case 0: guard varint() != nil else { return nil }
                case 1, 5:
                    let count = tag & 7 == 1 ? 8 : 4
                    guard count <= bytes.count - offset else { return nil }
                    offset += count
                case 2:
                    guard let length = varint(), length <= UInt64(bytes.count - offset) else { return nil }
                    let end = offset + Int(length)
                    fields[Int(tag >> 3), default: []].append(Data(bytes[offset..<end]))
                    offset = end
                default: return nil
                }
            }
        }
        func first(_ field: Int) -> Data? { fields[field]?.first }
        func text(_ field: Int) -> String? {
            guard let data = first(field), let value = String(data: data, encoding: .utf8) else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}
