import AppKit
import SwiftUI

/// Scroll only overflowing activity; keep animation updates local to the text view.
struct NotchActivityText: View {
    let text: String
    let width: CGFloat
    var color: Color = .white
    var isVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppPreferences.marqueeSpeedKey) private var marqueeSpeed = 1.0
    @State private var startedAt = Date()
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    static func displayText(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return text }
        let label = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let remainder = text[text.index(after: colon)...]
        // Provider activity uses "label: detail". Preserve URLs, paths, timestamps,
        // and ordinary punctuation instead of treating every colon as a tool label.
        guard !label.isEmpty, label.count <= 64,
              label.split(separator: " ").count <= 3,
              label.allSatisfy({ $0.isLetter || $0.isNumber || " _-/".contains($0) }),
              !["http", "https", "file", "ftp", "mailto"].contains(label),
              remainder.first?.isWhitespace == true else { return text }
        let content = remainder.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return text }
        let emoji: String
        if label.contains("thought") || label.contains("think") { emoji = "💭" }
        else if label.contains("response") || label.contains("reply") { emoji = "💬" }
        else if ["search", "explore", "grep", "glob", "find"].contains(where: label.contains) { emoji = "🔍" }
        else if ["write", "edit", "patch"].contains(where: label.contains) { emoji = "✏️" }
        else if label.contains("read") { emoji = "📄" }
        else if ["shell", "bash", "terminal", "command"].contains(where: label.contains) { emoji = "💻" }
        else if label.contains("subagent") || label.contains("task") { emoji = "🤖" }
        else if label.contains("compact") { emoji = "📦" }
        else if label.contains("workspace") { emoji = "📁" }
        else if label.contains("permission") || label.contains("approval") { emoji = "🔐" }
        else if label.contains("question") { emoji = "❓" }
        else if ["error", "fail", "timeout", "interrupt"].contains(where: label.contains) { emoji = "⚠️" }
        else { emoji = "🔧" } // Native tools can introduce new names without a UI change.
        return emoji + " " + content
    }

    var body: some View {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        Group {
            if textWidth > width && !reduceMotion && isVisible {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let gap: CGFloat = 28
                    let distance = textWidth + gap
                    let speed = 24 * (marqueeSpeed.isFinite ? min(2, max(0.5, marqueeSpeed)) : 1)
                    let cycle = Double(distance) / speed + 1.2
                    let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                    let travel = max(0, elapsed.truncatingRemainder(dividingBy: cycle) - 1.2) * speed
                    HStack(spacing: gap) {
                        Text(text).frame(width: textWidth, alignment: .leading)
                        Text(text).frame(width: textWidth, alignment: .leading)
                    }
                    .fixedSize()
                    .offset(x: -CGFloat(travel))
                    .frame(width: width, alignment: .leading)
                    .clipped()
                }
            } else {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, alignment: .center)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onChange(of: text) { _ in startedAt = Date() }
        .onChange(of: marqueeSpeed) { _ in startedAt = Date() }
        .onChange(of: isVisible) { visible in if visible { startedAt = Date() } }
    }
}
