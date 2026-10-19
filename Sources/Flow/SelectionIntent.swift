import AppKit
import Foundation

/// Was das Gesprochene bei markiertem Text bedeuten soll.
enum SelectionIntent: Equatable {
    /// Gesprochenes ist eine Anweisung an die Markierung.
    case command
    /// Gesprochenes ersetzt die Markierung (Umformulierung / neuer Text).
    case reformulate
    /// Beides denkbar — Nutzer wählt.
    case ambiguous
}

enum SelectionIntentClassifier {
    /// Kurze Markierungen (Wörter) gelten eher als Umformulierung.
    static let shortSelectionWords = 4

    static func classify(spoken: String, selection: String) -> SelectionIntent {
        let spokenTrim = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectionTrim = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenTrim.isEmpty, !selectionTrim.isEmpty else { return .command }

        let selWords = wordCount(selectionTrim)
        let spoWords = wordCount(spokenTrim)
        let similar = similarity(spokenTrim, selectionTrim)
        let cue = looksLikeCommand(spokenTrim)
        let short = selWords <= shortSelectionWords

        // Klare Anweisung und kaum Ähnlichkeit → Befehl.
        if cue && similar < 0.5 { return .command }

        // Kurze Markierung, stark ähnlich → Umformulierung.
        if short && similar >= 0.42 { return .reformulate }

        // Kurze Markierung ohne Befehlston, ähnlich lang → Umformulierung.
        if short && !cue && spoWords <= max(selWords + 5, 10) && similar >= 0.22 {
            return .reformulate
        }

        // Kurze Markierung mit Befehlston, aber auch ähnlich → unsicher.
        if short && cue && similar >= 0.28 { return .ambiguous }

        // Kurze Markierung, kein klarer Befehl, schwache Ähnlichkeit → unsicher.
        if short && !cue && spoWords <= max(selWords + 6, 12) { return .ambiguous }

        return .command
    }

    static func looksLikeCommand(_ spoken: String) -> Bool {
        let n = normalize(spoken)
        let cues = [
            "zusammenfass", "fass das", "fass es", "fass den", "fass die",
            "übersetz", "uebersetz", "translate", "summar",
            "kürz", "kuerz", "shorten", "kürzer", "kuerzer",
            "mach das", "mach es", "mach den", "mach die", "mach daraus", "make it", "make this",
            "formulier", "umformulier", "rephrase", "rewrite",
            "erklär", "erklaer", "explain",
            "korrigier", "korrekt", "proofread", "rechtschreib",
            "freundlicher", "förmlich", "foermlich", "formaler", "höflicher", "hoeflicher",
            "stichpunkt", "als liste", "bullet", "auf englisch", "auf deutsch", "ins englische", "ins deutsche",
            "kannst du", "könntest du", "koenntest du", "can you", "could you",
            "bitte das", "bitte den", "bitte die", "bitte mir das",
        ]
        return cues.contains { n.contains($0) }
    }

    /// Short status for the widget while a selection command runs.
    static func busyCaption(for spoken: String) -> String {
        let n = normalize(spoken)
        let rules: [(cues: [String], key: String)] = [
            (["zusammenfass", "fass das", "fass es", "fass den", "fass die", "summar"], "overlay.action.summarize"),
            (["übersetz", "uebersetz", "translate", "ins englische", "ins deutsche", "auf englisch", "auf deutsch"], "overlay.action.translate"),
            (["kürz", "kuerz", "shorten", "kürzer", "kuerzer"], "overlay.action.shorten"),
            (["stichpunkt", "als liste", "bullet"], "overlay.action.list"),
            (["erklär", "erklaer", "explain"], "overlay.action.explain"),
            (["korrigier", "korrekt", "proofread", "rechtschreib"], "overlay.action.proofread"),
            (["freundlicher", "höflicher", "hoeflicher"], "overlay.action.friendly"),
            (["förmlich", "foermlich", "formaler"], "overlay.action.formal"),
            (["formulier", "umformulier", "rephrase", "rewrite", "schreib um", "schreibe um"], "overlay.action.rewrite"),
        ]
        for rule in rules where rule.cues.contains(where: { n.contains($0) }) {
            return L10n.s(rule.key)
        }
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.s("overlay.rewrite") }
        if trimmed.count <= 28 { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 27)
        return String(trimmed[..<end]) + "…"
    }

    /// 0…1, höher = ähnlicher.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = normalize(a)
        let right = normalize(b)
        if left.isEmpty || right.isEmpty { return 0 }
        if left == right { return 1 }

        let leftTokens = Set(tokens(left))
        let rightTokens = Set(tokens(right))
        let tokenScore: Double
        if leftTokens.isEmpty || rightTokens.isEmpty {
            tokenScore = 0
        } else {
            let inter = leftTokens.intersection(rightTokens).count
            let union = leftTokens.union(rightTokens).count
            tokenScore = union == 0 ? 0 : Double(inter) / Double(union)
        }

        let distance = levenshtein(left, right)
        let maxLen = max(left.count, right.count)
        let editScore = maxLen == 0 ? 0 : 1 - (Double(distance) / Double(maxLen))

        let containsBonus: Double
        if left.contains(right) || right.contains(left) {
            containsBonus = 0.15
        } else {
            containsBonus = 0
        }

        return min(1, max(tokenScore, editScore) + containsBonus)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        return String(scalars)
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    private static func tokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}

enum OverlayResultSize: String, CaseIterable, Identifiable {
    case compact
    case regular
    case large

    var id: String { rawValue }

    var panelSize: NSSize {
        switch self {
        case .compact: return NSSize(width: 400, height: 440)
        case .regular: return NSSize(width: 520, height: 560)
        case .large: return NSSize(width: 640, height: 680)
        }
    }

    var cardWidth: CGFloat {
        switch self {
        case .compact: return 360
        case .regular: return 480
        case .large: return 600
        }
    }

    var cardMaxTextHeight: CGFloat {
        switch self {
        case .compact: return 280
        case .regular: return 360
        case .large: return 460
        }
    }

    var titleKey: String {
        switch self {
        case .compact: return "settings.resultSize.compact"
        case .regular: return "settings.resultSize.regular"
        case .large: return "settings.resultSize.large"
        }
    }
}

/// Feste Ecke oder Kante für Ergebnis- und Diktat-Vorschau-Karten.
enum ResultPlacementAnchor: String, CaseIterable, Identifiable {
    case topLeading
    case topCenter
    case topTrailing
    case bottomLeading
    case bottomCenter
    case bottomTrailing

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .topLeading: return "settings.resultPlace.topLeading"
        case .topCenter: return "settings.resultPlace.topCenter"
        case .topTrailing: return "settings.resultPlace.topTrailing"
        case .bottomLeading: return "settings.resultPlace.bottomLeading"
        case .bottomCenter: return "settings.resultPlace.bottomCenter"
        case .bottomTrailing: return "settings.resultPlace.bottomTrailing"
        }
    }
}
