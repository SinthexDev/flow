import AppKit

/// Until 1.9.2 the app shipped as `Flow.app`. Installers and updaters of those builds
/// can still leave that bundle behind; this moves the app to its current name.
enum LegacyName {
    static let bundleName = "Sinthex Flow.app"
    static let executableName = "Sinthex Flow"
    static let oldBundleName = "Flow.app"

    /// Renames a bundle that still carries the old name and starts it again from the new path.
    /// Returns true when this process should quit so the renamed copy can take over.
    static func relocateIfNeeded() -> Bool {
        let current = Bundle.main.bundleURL.standardizedFileURL
        guard current.lastPathComponent == oldBundleName else { return false }
        let target = current.deletingLastPathComponent().appendingPathComponent(bundleName, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            guard isOurs(target) else { return false }
            try? fm.removeItem(at: current)
        } else if (try? fm.moveItem(at: current, to: target)) == nil {
            return false
        }
        let command = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(UpdateCheck.shellQuote(target.path))"
        return (try? UpdateCheck.spawnDetached(["-c", command, "relaunch", "\(ProcessInfo.processInfo.processIdentifier)"])) != nil
    }

    /// Removes an old `Flow.app` of this app next to the current bundle or in /Applications.
    static func removeOldBundle() {
        let here = Bundle.main.bundleURL.standardizedFileURL
        guard here.lastPathComponent == bundleName else { return }
        let places = [
            here.deletingLastPathComponent().appendingPathComponent(oldBundleName, isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(oldBundleName, isDirectory: true)
        ]
        for old in Set(places) where old != here && isOurs(old) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static func isOurs(_ bundle: URL) -> Bool {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
    }
}
