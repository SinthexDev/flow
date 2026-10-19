import Foundation

struct FlowNote: Codable, Identifiable, Equatable {
    var id: UUID
    var created: Date
    var updated: Date
    var title: String
    var body: String

    var listTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return Self.derivedTitle(from: body)
    }

    static func derivedTitle(from body: String) -> String {
        let line = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return "" }
        if line.count <= 80 { return line }
        return String(line.prefix(80)) + "…"
    }
}

enum NoteSaveOutcome: Equatable {
    case flow
    case apple(folder: String)
    case fallback
}

/// Kurze Übersicht nach dem Speichern. Ein Klick öffnet den Ablageort.
struct SavedNotePreview: Equatable {
    enum Place: Equatable {
        case flow(UUID)
        case apple(account: String, folder: String, noteID: String?)
    }

    var body: String
    var place: Place

    var placeTitle: String {
        switch place {
        case .flow:
            return L10n.s("overlay.note.flow")
        case .apple(_, let folder, _):
            return folder
        }
    }
}

/// Wie eine gesprochene Notiz mit der Markierung umgehen soll.
enum NoteSaveKind: Equatable {
    /// Die Markierung selbst ablegen.
    case verbatim
    /// Die Anweisung anhand der Markierung beantworten und nur die Antwort ablegen.
    case answer
}

/// Gesprochenes, das eine Notiz aus der Markierung machen soll.
enum NoteSaveCommand {
    static func kind(_ spoken: String) -> NoteSaveKind? {
        let normalized = normalize(spoken)
        guard !normalized.isEmpty else { return nil }
        let tokens = normalized.split(separator: " ").map(String.init)
        guard mentionsNotes(tokens) else { return nil }
        guard saveVerb(tokens) || mentionsDestination(normalized) else { return nil }
        if rewriteIntent(normalized) { return .answer }
        let leftover = tokens.filter { !isFrameWord($0) }
        return leftover.isEmpty ? .verbatim : .answer
    }

    private static func mentionsDestination(_ normalized: String) -> Bool {
        let destinations = [
            "in meinen notizen",
            "in die notizen",
            "in den notizen",
            "in my notes",
            "to my notes",
            "into my notes",
            "into notes",
            "to notes",
        ]
        return destinations.contains { normalized.contains($0) }
    }

    private static func isFrameWord(_ token: String) -> Bool {
        if frameWords.contains(token) { return true }
        return saveVerb([token])
    }

    private static let frameWords: Set<String> = [
        "mir", "mich", "dir", "uns", "bitte", "mal", "doch", "einfach", "nun", "jetzt",
        "auch", "noch", "schnell", "das", "dem", "den", "die", "der", "des",
        "ein", "eine", "einen", "einem", "einer", "es", "ihn", "sie", "ihnen", "du",
        "als", "in", "im", "meinen", "meine", "meinem", "meiner", "mein",
        "notiz", "notizen", "note", "notes",
        "text", "markierung", "auswahl", "absatz", "satz", "hier", "davon", "daraus",
        "diesen", "diese", "dieses",
        "auf", "zu", "zur", "zum", "von", "vom", "fur", "mit", "und", "oder", "dann",
        "to", "my", "into", "the", "a", "an", "this", "it", "as", "please", "just", "selection",
    ]

    private static func mentionsNotes(_ tokens: [String]) -> Bool {
        tokens.contains { token in
            token == "notes" || token == "note" || token.hasPrefix("notiz")
        }
    }

    private static func saveVerb(_ tokens: [String]) -> Bool {
        let prefixes = ["speicher", "save", "ableg", "ubernimm", "ubernehm", "kopier", "behalt", "sicherstell"]
        let exact = ["copy", "keep", "add", "put", "nimm", "pack", "sichere", "sichern"]
        for token in tokens {
            if exact.contains(token) { return true }
            if prefixes.contains(where: { token.hasPrefix($0) }) { return true }
        }
        return false
    }

    private static func rewriteIntent(_ normalized: String) -> Bool {
        let cues = [
            "formulier", "umschreib", "zusammenfass", "fass ", "kurz", "ubersetz",
            "korrigier", "rewrite", "summar", "shorten", "translate", "proofread", "erklar", "explain",
        ]
        return cues.contains { normalized.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(scalar) : " "
        }
        return String(scalars).split { $0.isWhitespace }.joined(separator: " ")
    }
}

enum NoteStore {
    static func load() -> [FlowNote] {
        if SnapshotMode.isActive { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: SupportPaths.notes),
              let notes = try? decoder.decode([FlowNote].self, from: data) else { return [] }
        return notes
    }

    static func save(_ notes: [FlowNote]) {
        if SnapshotMode.isActive { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else {
            Timing.mark("note file encode failed")
            return
        }
        do {
            try data.write(to: SupportPaths.notes, options: .atomic)
        } catch {
            Timing.mark("note file write failed")
        }
    }
}
