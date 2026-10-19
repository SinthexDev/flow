import Foundation

struct AppleNotesFolder: Identifiable, Equatable, Hashable {
    var account: String
    var name: String

    var id: String { Self.id(account: account, name: name) }
    var menuTitle: String { "\(name) · \(account)" }

    static func id(account: String, name: String) -> String {
        "\(account)\u{1e}\(name)"
    }

    static func decode(_ stored: String) -> AppleNotesFolder? {
        let parts = stored.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let account = String(parts[0])
        let name = String(parts[1])
        guard !account.isEmpty, !name.isEmpty else { return nil }
        return AppleNotesFolder(account: account, name: name)
    }
}

enum AppleNotes {
    private static let hiddenFolders: Set<String> = [
        "recently deleted",
        "zuletzt geloscht",
    ]

    static func folders() async throws -> [AppleNotesFolder] {
        let script = """
        tell application "Notes"
            set collected to ""
            repeat with a in accounts
                set accountName to name of a as text
                repeat with f in folders of a
                    set collected to collected & accountName & tab & (name of f as text) & linefeed
                end repeat
            end repeat
            return collected
        end tell
        """
        let output = try await run(script)
        var seen = Set<String>()
        var folders: [AppleNotesFolder] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let account = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty, !name.isEmpty else { continue }
            let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if hiddenFolders.contains(folded) { continue }
            let folder = AppleNotesFolder(account: account, name: name)
            guard seen.insert(folder.id).inserted else { continue }
            folders.append(folder)
        }
        return folders.sorted {
            if $0.account == $1.account { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.account.localizedStandardCompare($1.account) == .orderedAscending
        }
    }

    static func createNote(title: String, body: String, account: String, folder: String) async throws -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = heading.isEmpty ? "Notiz" : heading
        let script = """
        tell application "Notes"
            tell account \(appleString(account))
                tell folder \(appleString(folder))
                    set made to make new note with properties {name:\(appleString(name)), body:\(appleString(htmlBody(body)))}
                    return id of made as text
                end tell
            end tell
        end tell
        """
        return try await run(script).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Öffnet die Notizen-App und zeigt die gespeicherte Notiz, sonst die neueste im Ordner.
    static func reveal(account: String, folder: String, noteID: String?) async throws {
        let id = noteID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let script = """
        tell application "Notes"
            activate
            set opened to false
            if \(appleString(id)) is not "" then
                try
                    set theNote to first note whose id is \(appleString(id))
                    show theNote
                    set opened to true
                end try
            end if
            if opened is false then
                tell account \(appleString(account))
                    tell folder \(appleString(folder))
                        if (count of notes) > 0 then
                            set theNote to first note whose creation date is (maximum of creation date of notes)
                            show theNote
                        end if
                    end tell
                end tell
            end if
        end tell
        """
        _ = try await run(script)
    }

    private static let rememberedKey = "flow.lastAppleNoteID"

    static func remember(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: rememberedKey)
    }

    static func rememberedID() -> String? {
        let value = UserDefaults.standard.string(forKey: rememberedKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func htmlBody(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<div>\(escaped)</div>"
    }

    private static func appleString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func run(_ source: String, timeout: TimeInterval = 90) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let once = ResumeOnce()
            process.terminationHandler = { process in
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                once.run {
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: AppleNotesFailure(output: errorText.isEmpty ? text : errorText))
                    }
                }
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                once.run { continuation.resume(throwing: error) }
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                once.run { continuation.resume(throwing: AppleNotesFailure(output: "timeout")) }
            }
        }
    }
}

struct AppleNotesFailure: Error {
    var output: String

    var denied: Bool {
        let folded = output.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.contains("-1743")
            || folded.contains("not authorized")
            || folded.contains("nicht berechtigt")
            || folded.contains("nicht erlaubt")
            || folded.contains("-1002")
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        if shouldRun { done = true }
        lock.unlock()
        if shouldRun { body() }
    }
}
