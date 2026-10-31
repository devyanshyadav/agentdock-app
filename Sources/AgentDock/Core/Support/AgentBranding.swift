import Foundation

/// Public author and publisher links shown in About, License, and bundled metadata.
enum AgentBranding {
    static let authorName = "Devyansh"
    static let authorURL = URL(string: "https://devyanshyadav.com")!

    static let publisherName = "Silicon Apps"
    static let publisherURL = URL(string: "https://siliconapps.dev")!

    /// AgentDock product page on Silicon Apps.
    static let productURL = URL(string: "https://agentdock.siliconapps.dev")!

    static let repositoryURL = URL(string: "https://github.com/devyanshyadav/agentdock-app")!

    static let copyrightLine = "Copyright © 2026 Devyansh Yadav · \(publisherName)."
}
