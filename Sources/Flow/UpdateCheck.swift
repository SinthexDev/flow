import AppKit
import Darwin
import Foundation

struct AppRelease: Equatable {
    var version: String
    var pkgURL: URL
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case current
    case available(AppRelease)
    case downloading(AppRelease)
    case failed
}

enum UpdateCheck {
    static let feed = URL(string: "https://sinthex.de/flow/latest.json")!
    static let page = URL(string: "https://sinthex.de/flow/")!
    private static let dismissedKey = "flow.dismissedUpdate"

    private struct Payload: Decodable {
        var version: String
        var pkg: String
    }

    static var dismissedVersion: String {
        get { UserDefaults.standard.string(forKey: dismissedKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = parts(remote)
        let localParts = parts(local)
        let count = max(remoteParts.count, localParts.count)
        for index in 0..<count {
            let remoteValue = index < remoteParts.count ? remoteParts[index] : 0
            let localValue = index < localParts.count ? localParts[index] : 0
            if remoteValue != localValue { return remoteValue > localValue }
        }
        return false
    }

    static func fetch() async throws -> AppRelease {
        var request = URLRequest(url: feed)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, let pkg = URL(string: payload.pkg) else {
            throw URLError(.cannotParseResponse)
        }
        return AppRelease(version: version, pkgURL: pkg)
    }

    static func download(_ release: AppRelease) async throws -> URL {
        var request = URLRequest(url: release.pkgURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 180
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Sinthex-Flow-\(release.version).pkg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        clear.arguments = ["-d", "com.apple.quarantine", dest.path]
        try? clear.run()
        clear.waitUntilExit()
        return dest
    }

    /// Expands the package, then a detached script replaces the running app and opens it again.
    /// The package file itself is never opened. A root-owned copy asks for the password once
    /// and is then given to the user, so the next update needs no prompt.
    static func stageRelaunch(pkg: URL, version: String) throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SinthexFlowUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let expanded = work.appendingPathComponent("expanded", isDirectory: true)
        let expand = Process()
        expand.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        expand.arguments = ["--expand-full", pkg.path, expanded.path]
        try expand.run()
        expand.waitUntilExit()
        guard expand.terminationStatus == 0,
              let source = flowApp(in: expanded, version: version) else {
            throw URLError(.cannotDecodeContentData)
        }
        let staged = work.appendingPathComponent("next.app", isDirectory: true)
        guard ditto(source, to: staged) else { throw URLError(.cannotCreateFile) }
        let destination = Bundle.main.bundleURL.standardizedFileURL
        guard destination.pathExtension == "app" else { throw URLError(.cannotCreateFile) }
        let script = work.appendingPathComponent("relaunch.sh")
        let body = relaunchScript(
            staged: staged,
            destination: destination,
            owner: NSUserName(),
            group: groupName()
        )
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try spawnDetached([script.path, "\(ProcessInfo.processInfo.processIdentifier)"])
    }

    private static func flowApp(in root: URL, version: String) -> URL? {
        guard let found = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in found where url.lastPathComponent == LegacyName.bundleName {
            let info = url.appendingPathComponent("Contents/Info.plist")
            let binary = url.appendingPathComponent("Contents/MacOS/\(LegacyName.executableName)")
            guard FileManager.default.isExecutableFile(atPath: binary.path),
                  let dict = NSDictionary(contentsOf: info),
                  dict["CFBundleIdentifier"] as? String == "de.sinthex.flow",
                  dict["CFBundleShortVersionString"] as? String == version else { continue }
            return url
        }
        return nil
    }

    private static func ditto(_ source: URL, to destination: URL) -> Bool {
        try? FileManager.default.removeItem(at: destination)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [source.path, destination.path]
        guard (try? copy.run()) != nil else { return false }
        copy.waitUntilExit()
        let binary = destination.appendingPathComponent("Contents/MacOS/\(LegacyName.executableName)")
        return copy.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: binary.path)
    }

    private static func relaunchScript(staged: URL, destination: URL, owner: String, group: String) -> String {
        let stagedPath = shellQuote(staged.path)
        let destinationPath = shellQuote(destination.path)
        let ownerName = shellQuote(owner)
        let groupName = shellQuote(group)
        return """
        #!/bin/bash
        trap '' HUP TERM
        src=\(stagedPath)
        dest=\(destinationPath)
        owner=\(ownerName)
        group=\(groupName)
        log="${HOME}/Library/Logs/Sinthex Flow-update.log"
        mkdir -p "$(dirname "$log")"
        exec >>"$log" 2>&1
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') update start parent=$1"
        for _ in $(seq 1 150); do
          kill -0 "$1" 2>/dev/null || break
          sleep 0.2
        done
        sleep 0.4
        if rm -rf "$dest" && /usr/bin/ditto "$src" "$dest"; then
          /usr/bin/xattr -cr "$dest" || true
          echo "replaced $dest"
        else
          echo "privileged replace $dest"
          /usr/bin/osascript -e 'on run argv
            set destPath to item 1 of argv
            set srcPath to item 2 of argv
            set ownerName to item 3 of argv
            set groupName to item 4 of argv
            do shell script "rm -rf " & quoted form of destPath & " && /usr/bin/ditto " & quoted form of srcPath & " " & quoted form of destPath & " && /usr/sbin/chown -R " & quoted form of (ownerName & ":" & groupName) & " " & quoted form of destPath & " && /usr/bin/xattr -cr " & quoted form of destPath with administrator privileges
          end run' -- "$dest" "$src" "$owner" "$group"
        fi
        /usr/bin/open "$dest"
        echo "update finished"
        """
    }

    /// Runs `/bin/bash` with these arguments in its own session, so it outlives the app.
    static func spawnDetached(_ arguments: [String]) throws {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw URLError(.cannotOpenFile) }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) == 0 else {
            throw URLError(.cannotOpenFile)
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw URLError(.cannotOpenFile) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let argvPointers = ["/bin/bash"] + arguments
        var cArgs = argvPointers.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, "/bin/bash", &actions, &attr, &cArgs, environ)
        guard result == 0 else { throw URLError(.cannotOpenFile) }
    }

    private static func groupName() -> String {
        let pipe = Pipe()
        let id = Process()
        id.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        id.arguments = ["-gn"]
        id.standardOutput = pipe
        guard (try? id.run()) != nil else { return "staff" }
        id.waitUntilExit()
        let name = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "staff" : name
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
