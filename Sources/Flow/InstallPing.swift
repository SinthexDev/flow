import CryptoKit
import Foundation
import IOKit

/// Once per Mac, tells Sinthex that this copy launched. The payload is a hash of the
/// hardware UUID, not the computer name (those are easy to guess).
enum InstallPing {
    static let endpoint = URL(string: "https://sinthex.de/flow/install.php")!

    private static var stamp: URL {
        SupportPaths.directory.appendingPathComponent("install.sent")
    }

    static func sendIfNeeded(enabled: Bool) {
        guard enabled, !SnapshotMode.isActive else { return }
        guard !FileManager.default.fileExists(atPath: stamp.path) else { return }
        guard let id = anonymousId() else { return }
        let version = L10n.appVersion
        Task.detached(priority: .utility) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "id": id,
                "v": version,
            ])
            guard request.httpBody != nil else { return }
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return }
            try? version.write(to: stamp, atomically: true, encoding: .utf8)
        }
    }

    private static func anonymousId() -> String? {
        guard let uuid = platformUUID() else { return nil }
        let digest = SHA256.hash(data: Data("sinthex-flow\n\(uuid)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return raw.takeRetainedValue() as? String
    }
}
