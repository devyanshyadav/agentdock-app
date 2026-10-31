import AppKit
import Foundation

@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private static let manifestURL: URL = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "UpdateManifestURL") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               !trimmed.localizedCaseInsensitiveContains("REPLACE"),
               let url = URL(string: trimmed) {
                return url
            }
        }
        return URL(string: "https://agentdock.siliconapps.dev/update.json")!
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private var isChecking = false

    private init() {}

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        NSApp.activate(ignoringOtherApps: true)

        Task {
            defer { isChecking = false }
            await performCheck()
        }
    }

    private func performCheck() async {
        do {
            let (data, response) = try await session.data(from: Self.manifestURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                showOKAlert(
                    "Could Not Check for Updates",
                    (response as? HTTPURLResponse)?.statusCode == 404
                        ? "update.json was not found on the update server."
                        : "The update server returned an error. Try again later."
                )
                return
            }

            let manifest = try JSONDecoder().decode(Manifest.self, from: data)

            guard manifest.build > AppVersion.build else {
                showOKAlert("You're Up to Date", "AgentDock \(AppVersion.short) is the latest version.")
                return
            }

            presentUpdateAlert(manifest)
        } catch {
            showOKAlert("Could Not Check for Updates", "Check your internet connection and try again.")
        }
    }

    private func presentUpdateAlert(_ manifest: Manifest) {
        var message = "AgentDock \(manifest.version) is available. You have \(AppVersion.short)."
        if let notes = manifest.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            message += "\n\n\(notes)"
        }

        let dialog = NSAlert()
        dialog.alertStyle = .informational
        dialog.messageText = "Update Available"
        dialog.informativeText = message
        dialog.addButton(withTitle: "Download Update")
        dialog.addButton(withTitle: "Later")

        if dialog.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: manifest.downloadURL) {
                NSWorkspace.shared.open(url)
            } else {
                showOKAlert("Invalid Download Link", "The update manifest has an invalid download URL.")
            }
        }
    }

    private func showOKAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct Manifest: Decodable {
    let version: String
    let build: Int
    let downloadURL: String
    let releaseNotes: String?
}
