import AppKit
import Darwin
import IOKit.pwr_mgt

/// Desktop agents that keep working in the background hold a macOS power assertion for exactly as long
/// as a turn is running (Cursor shows `NoIdleSleepAssertion "Electron"` for its agent loop). That is
/// an operating-system fact rather than a log line or a hook, so it still reports "finished" when a
/// cancelled request kills the app's own stop hook.
enum PowerAssertionProbe {
    /// Bundle identifiers of running apps that currently hold an idle-sleep assertion.
    static func holdingBundleIdentifiers() -> Set<String> {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPID = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let preventing: Set<String> = ["NoIdleSleepAssertion", "PreventUserIdleSystemSleep", "PreventSystemSleep"]
        var result = Set<String>()
        for (pid, assertions) in byPID where assertions.contains(where: { preventing.contains($0["AssertType"] as? String ?? "") }) {
            let pidValue = pid_t(truncating: pid)
            if let bundle = NSRunningApplication(processIdentifier: pidValue)?.bundleIdentifier ?? rootAppBundleIdentifier(for: pidValue) {
                result.insert(bundle)
            }
        }
        return result
    }

    /// Resolves the enclosing `.app` bundle identifier for helper/child processes (e.g. Electron helpers or language servers).
    private static func rootAppBundleIdentifier(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let appPath = String(path[..<range.upperBound].dropLast())
        return Bundle(path: appPath)?.bundleIdentifier
    }
}
