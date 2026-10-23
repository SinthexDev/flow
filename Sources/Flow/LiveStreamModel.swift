import AppKit
import Foundation
import SwiftUI

struct LiveToken: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Erkannt und über zwei Durchläufe gleich.
        case raw
        /// Letzte Wörter, die sich noch ändern können.
        case tail
        /// Das Sprachmodell hat diese Wörter gerade im Blick.
        case selected
        /// Altes Wort geht nach oben weg.
        case leaving
        /// Korrektur schwebt von unten ein.
        case entering
        case polished
    }

    let id: UUID
    var text: String
    var phase: Phase
    var sentenceID: UUID
}

struct LiveSentence: Identifiable, Equatable {
    enum State: Equatable {
        case open
        case polishing
        case committing
    }

    let id: UUID
    var tokenIDs: [UUID]
    var state: State
    var failed: Bool = false
}

/// Sichtbarer Flow-Stream-Text. Die Session füttert Wörter, die Karte zeichnet nur.
/// Alle Aufrufe laufen auf dem Hauptthread.
final class LiveStreamModel: ObservableObject {
    @Published private(set) var tokens: [UUID: LiveToken] = [:]
    @Published private(set) var sentences: [LiveSentence] = []
    @Published var committedCount = 0
    @Published var degraded = false
    @Published var lineCount = 1
    @Published var overflows = false
    @Published var commitPulse = false
    @Published var copiedFlash = false
    var reduceMotion = false

    private var estimateWidth: CGFloat = 360

    var polishingCount: Int {
        sentences.filter { $0.state == .polishing }.count
    }

    var orderedTokens: [LiveToken] {
        sentences.flatMap { sentence in
            sentence.tokenIDs.compactMap { tokens[$0] }
        }
    }

        func reset() {
        tokens = [:]
        sentences = []
        committedCount = 0
        degraded = false
        lineCount = 1
        overflows = false
        commitPulse = false
        copiedFlash = false
    }

        func noteWidth(_ width: CGFloat) {
        guard width > 1, abs(width - estimateWidth) > 0.5 else { return }
        estimateWidth = width
        refreshOverflow()
    }

    /// Zeilen, wie sie das Layout wirklich umbricht. Kommt aus der Karte.
        func reportLines(_ lines: Int) {
        let clamped = min(LiveStreamLayout.maxLines, max(1, lines))
        if clamped != lineCount { lineCount = clamped }
    }

    // MARK: Erkennung

    /// Offener Satz. `words` ist der gesamte noch nicht abgeschlossene Text, die ersten
    /// `stableCount` Wörter sind stabil. Unveränderte Wörter behalten ihre Identität.
        func setOpen(words: [String], stableCount: Int) {
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.18)
        withAnimation(animation) {
            applyOpen(words: words, stableCount: stableCount)
        }
        refreshOverflow()
    }

    /// Löst die ersten `count` Wörter aus dem offenen Satz und schickt sie in die Korrektur.
    /// Die Wörter bleiben dieselben Views und rutschen nur in den neuen Satz.
        func closeSentence(wordCount count: Int) -> UUID? {
        guard count > 0, let openIndex = sentences.firstIndex(where: { $0.state == .open }) else { return nil }
        let ids = sentences[openIndex].tokenIDs
        guard ids.count >= count else { return nil }
        let take = Array(ids.prefix(count))
        let rest = Array(ids.dropFirst(count))
        let newID = UUID()
        let sentence = LiveSentence(id: newID, tokenIDs: take, state: .polishing)
        withAnimation(.easeOut(duration: 0.16)) {
            for id in take {
                tokens[id]?.sentenceID = newID
                tokens[id]?.phase = .raw
            }
            if rest.isEmpty {
                sentences[openIndex] = sentence
            } else {
                sentences[openIndex].tokenIDs = rest
                sentences.insert(sentence, at: openIndex)
            }
        }
        refreshOverflow()
        return newID
    }

    // MARK: Korrektur

    private struct HunkPlan {
        var anchor: UUID?
        var oldIDs: [UUID]
        var words: [String]
    }

    /// Spielt die Korrektur eines Satzes und ruft `insert` genau beim Start des Satz-Commits auf.
    @MainActor
    func play(sentenceID: UUID, polishedWords: [String], failed: Bool, insert: () -> Void) async {
        guard let index = sentences.firstIndex(where: { $0.id == sentenceID }) else {
            insert()
            return
        }
        if failed {
            withAnimation(.easeOut(duration: 0.12)) { sentences[index].failed = true }
            _ = await pause(260)
        }
        let ids = sentences[index].tokenIDs
        let oldWords = ids.compactMap { tokens[$0]?.text }
        let hunks = failed ? [] : LiveText.diff(old: oldWords, new: polishedWords, loose: false)

        if reduceMotion {
            if !hunks.isEmpty { await crossfade(sentenceID: sentenceID, words: polishedWords) }
        } else if hunks.count >= 6 {
            await crossfade(sentenceID: sentenceID, words: polishedWords)
        } else if !hunks.isEmpty {
            let merged = hunks.count > 4
                ? [LiveText.Hunk(start: 0, remove: oldWords.count, replacement: polishedWords)]
                : hunks
            let plans: [HunkPlan] = merged.map { hunk in
                let end = min(ids.count, hunk.start + hunk.remove)
                let start = min(hunk.start, end)
                return HunkPlan(
                    anchor: start > 0 ? ids[start - 1] : nil,
                    oldIDs: Array(ids[start..<end]),
                    words: hunk.replacement
                )
            }
            let tight = plans.count > 1
            let skipSelect = plans.count >= 3
            await withTaskGroup(of: Void.self) { group in
                for (position, plan) in plans.enumerated() {
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return }
                        await self.run(
                            plan: plan,
                            sentenceID: sentenceID,
                            delay: UInt64(position) * 70,
                            tight: tight,
                            skipSelect: skipSelect
                        )
                    }
                }
            }
        }
        if Task.isCancelled { return }
        ripen(sentenceID: sentenceID)
        _ = await pause(reduceMotion ? 80 : 150)
        await commit(sentenceID: sentenceID, insert: insert)
    }

        func noteInserted(copied: Bool) {
        committedCount += 1
        withAnimation(.easeOut(duration: 0.15)) {
            commitPulse = true
            copiedFlash = copied
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                self.commitPulse = false
                self.copiedFlash = false
            }
        }
    }

    // MARK: Intern

        private func applyOpen(words: [String], stableCount: Int) {
        guard let index = sentences.firstIndex(where: { $0.state == .open }) else {
            guard !words.isEmpty else { return }
            let sentenceID = UUID()
            var ids: [UUID] = []
            for (offset, word) in words.enumerated() {
                let tokenID = UUID()
                tokens[tokenID] = LiveToken(
                    id: tokenID,
                    text: word,
                    phase: offset < stableCount ? .raw : .tail,
                    sentenceID: sentenceID
                )
                ids.append(tokenID)
            }
            sentences.append(LiveSentence(id: sentenceID, tokenIDs: ids, state: .open))
            return
        }
        let sentenceID = sentences[index].id
        var ids = sentences[index].tokenIDs
        let oldWords = ids.compactMap { tokens[$0]?.text }
        let hunks = LiveText.diff(old: oldWords, new: words, loose: true)
        for hunk in hunks.reversed() {
            let lower = min(hunk.start, ids.count)
            let upper = min(ids.count, hunk.start + hunk.remove)
            if lower < upper {
                for id in ids[lower..<upper] { tokens[id] = nil }
                ids.removeSubrange(lower..<upper)
            }
            let fresh: [UUID] = hunk.replacement.map { word in
                let tokenID = UUID()
                tokens[tokenID] = LiveToken(id: tokenID, text: word, phase: .tail, sentenceID: sentenceID)
                return tokenID
            }
            ids.insert(contentsOf: fresh, at: lower)
        }
        // Gleiche Wörter mit anderer Zeichensetzung behalten die View und tauschen nur den Text.
        for (position, id) in ids.enumerated() where position < words.count {
            guard var token = tokens[id] else { continue }
            let phase: LiveToken.Phase = position < stableCount ? .raw : .tail
            if token.text != words[position] || token.phase != phase {
                token.text = words[position]
                token.phase = phase
                tokens[id] = token
            }
        }
        if ids.isEmpty {
            sentences.remove(at: index)
        } else {
            sentences[index].tokenIDs = ids
        }
    }

    @MainActor
    private func run(plan: HunkPlan, sentenceID: UUID, delay: UInt64, tight: Bool, skipSelect: Bool) async {
        let factor = tight ? 0.7 : 1.0
        if delay > 0 { guard await pause(delay) else { return } }
        if !plan.oldIDs.isEmpty {
            if !skipSelect {
                withAnimation(.easeOut(duration: 0.12)) { setPhase(plan.oldIDs, .selected) }
                guard await pause(UInt64(150 * factor)) else { return }
            }
            withAnimation(.easeIn(duration: 0.16)) { setPhase(plan.oldIDs, .leaving) }
            guard await pause(UInt64(120 * factor)) else { return }
        }
        var newIDs: [UUID] = []
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            newIDs = swap(sentenceID: sentenceID, anchor: plan.anchor, remove: plan.oldIDs, words: plan.words)
        }
        refreshOverflow()
        guard await pause(UInt64(170 * factor)) else { return }
        withAnimation(.easeOut(duration: 0.22)) { setPhase(newIDs, .polished) }
    }

        private func swap(sentenceID: UUID, anchor: UUID?, remove: [UUID], words: [String]) -> [UUID] {
        guard let index = sentences.firstIndex(where: { $0.id == sentenceID }) else { return [] }
        var ids = sentences[index].tokenIDs
        for id in remove {
            tokens[id] = nil
        }
        ids.removeAll { remove.contains($0) }
        var position = 0
        if let anchor, let found = ids.firstIndex(of: anchor) { position = found + 1 }
        let created: [UUID] = words.map { word in
            let tokenID = UUID()
            tokens[tokenID] = LiveToken(id: tokenID, text: word, phase: .entering, sentenceID: sentenceID)
            return tokenID
        }
        ids.insert(contentsOf: created, at: min(position, ids.count))
        sentences[index].tokenIDs = ids
        return created
    }

    @MainActor
    private func crossfade(sentenceID: UUID, words: [String]) async {
        guard let index = sentences.firstIndex(where: { $0.id == sentenceID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            for id in sentences[index].tokenIDs { tokens[id] = nil }
            var ids: [UUID] = []
            for word in words {
                let tokenID = UUID()
                tokens[tokenID] = LiveToken(id: tokenID, text: word, phase: .polished, sentenceID: sentenceID)
                ids.append(tokenID)
            }
            sentences[index].tokenIDs = ids
        }
        refreshOverflow()
        _ = await pause(reduceMotion ? 120 : 220)
    }

    /// Nach der Korrektur wird der ganze Satz gleichmäßig hell.
        private func ripen(sentenceID: UUID) {
        guard let sentence = sentences.first(where: { $0.id == sentenceID }) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            setPhase(sentence.tokenIDs, .polished)
        }
    }

    @MainActor
    private func commit(sentenceID: UUID, insert: () -> Void) async {
        guard let index = sentences.firstIndex(where: { $0.id == sentenceID }) else {
            insert()
            return
        }
        // Einfügen und Wegschieben starten im selben Moment.
        withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .easeIn(duration: 0.24)) {
            sentences[index].state = .committing
        }
        insert()
        _ = await pause(reduceMotion ? 160 : 250)
        guard let current = sentences.firstIndex(where: { $0.id == sentenceID }) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.88)) {
            for id in sentences[current].tokenIDs { tokens[id] = nil }
            sentences.remove(at: current)
        }
        refreshOverflow()
        _ = await pause(60)
    }

        private func setPhase(_ ids: [UUID], _ phase: LiveToken.Phase) {
        for id in ids {
            guard var token = tokens[id] else { continue }
            token.phase = phase
            tokens[id] = token
        }
    }

    @MainActor
    private func pause(_ milliseconds: UInt64) async -> Bool {
        if Task.isCancelled { return false }
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        return !Task.isCancelled
    }

        private func refreshOverflow() {
        let texts = orderedTokens.map(\.text)
        let full = LiveText.lineCount(words: texts, width: max(120, estimateWidth - 28))
        let over = full > LiveStreamLayout.maxLines
        if over != overflows { overflows = over }
    }
}

enum LiveText {
    struct Hunk: Equatable {
        var start: Int
        var remove: Int
        var replacement: [String]
    }

    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "z.b", "d.h", "u.a", "u.u", "o.ä", "ca", "ggf",
        "bzw", "usw", "etc", "nr", "abs", "vgl", "bsp", "evtl", "inkl", "exkl", "geb", "co", "inc",
        "ltd", "ff", "fig", "no", "vol", "str", "tel"
    ]

    static func tokens(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    /// Wort ohne Zeichensetzung und Großschreibung. Whisper ändert beides von Durchlauf zu Durchlauf.
    static func loose(_ word: String) -> String {
        let stripped = word.lowercased().filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty ? word.lowercased() : stripped
    }

    /// Neue Wörter nach den schon übergebenen. Mit `dedupe` wird ein Überlapp am Anfang entfernt.
    static func freshWords(transcript: String, committed: String, dedupe: Bool) -> [String] {
        let words = tokens(transcript)
        guard dedupe else { return words }
        let done = tokens(committed)
        guard !done.isEmpty else { return words }
        if words.count >= done.count && zip(words, done).allSatisfy({ loose($0.0) == loose($0.1) }) {
            return Array(words.dropFirst(done.count))
        }
        let cap = min(done.count, words.count, 16)
        var drop = 0
        if cap > 0 {
            for length in stride(from: cap, through: 1, by: -1) {
                let prefix = words.prefix(length)
                let suffix = done.suffix(length)
                if zip(prefix, suffix).allSatisfy({ loose($0.0) == loose($0.1) }) {
                    drop = length
                    break
                }
            }
        }
        return Array(words.dropFirst(drop))
    }

    static func commonPrefixCount(_ lhs: [String], _ rhs: [String], loose useLoose: Bool) -> Int {
        let count = min(lhs.count, rhs.count)
        var index = 0
        while index < count {
            let same = useLoose ? loose(lhs[index]) == loose(rhs[index]) : lhs[index] == rhs[index]
            if !same { break }
            index += 1
        }
        return index
    }

    /// Komplette Sätze aus `words`. Ohne `flush` bleibt der unvollständige Rest stehen.
    static func sentences(in words: [String], flush: Bool) -> (complete: [[String]], rest: [String]) {
        var complete: [[String]] = []
        var current: [String] = []
        for word in words {
            current.append(word)
            if endsSentence(word) {
                complete.append(current)
                current = []
            }
        }
        if flush, !current.isEmpty {
            complete.append(current)
            current = []
        }
        return (complete, current)
    }

    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’»«()[]"))
        guard let last = trimmed.last, ".!?…".contains(last) else { return false }
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") { return true }
        let core = String(trimmed.dropLast()).lowercased()
        if core.isEmpty || core.count == 1 { return false }
        if abbreviations.contains(core) { return false }
        if core.contains(".") { return false }
        if core.allSatisfy({ $0.isNumber || $0 == "," }) { return false }
        return true
    }

    /// Wort-Diff. `loose` vergleicht ohne Zeichensetzung (Erkennung), sonst exakt (Korrektur).
    static func diff(old: [String], new: [String], loose useLoose: Bool) -> [Hunk] {
        func key(_ word: String) -> String { useLoose ? loose(word) : word }
        let oldKeys = old.map(key)
        let newKeys = new.map(key)
        if oldKeys == newKeys { return [] }
        let rows = oldKeys.count
        let columns = newKeys.count
        if rows * columns > 6_000 {
            return [Hunk(start: 0, remove: rows, replacement: new)]
        }
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        if rows > 0 && columns > 0 {
            for row in stride(from: rows - 1, through: 0, by: -1) {
                for column in stride(from: columns - 1, through: 0, by: -1) {
                    if oldKeys[row] == newKeys[column] {
                        table[row][column] = table[row + 1][column + 1] + 1
                    } else {
                        table[row][column] = max(table[row + 1][column], table[row][column + 1])
                    }
                }
            }
        }
        var hunks: [Hunk] = []
        var pendingStart = 0
        var pendingRemove = 0
        var pendingNew: [String] = []
        func flush() {
            if pendingRemove > 0 || !pendingNew.isEmpty {
                hunks.append(Hunk(start: pendingStart, remove: pendingRemove, replacement: pendingNew))
            }
            pendingRemove = 0
            pendingNew = []
        }
        var row = 0
        var column = 0
        while row < rows && column < columns {
            if oldKeys[row] == newKeys[column] {
                flush()
                row += 1
                column += 1
            } else if table[row + 1][column] >= table[row][column + 1] {
                if pendingRemove == 0 && pendingNew.isEmpty { pendingStart = row }
                pendingRemove += 1
                row += 1
            } else {
                if pendingRemove == 0 && pendingNew.isEmpty { pendingStart = row }
                pendingNew.append(new[column])
                column += 1
            }
        }
        if row < rows || column < columns {
            if pendingRemove == 0 && pendingNew.isEmpty { pendingStart = row }
            pendingRemove += rows - row
            if column < columns { pendingNew.append(contentsOf: new[column...]) }
        }
        flush()
        return hunks
    }

    /// Schätzung der Zeilen, nur für die Ausblendung oben. Die Panelhöhe kommt vom Layout.
    static func lineCount(words: [String], width: CGFloat) -> Int {
        guard !words.isEmpty else { return 1 }
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        var lines = 1
        var x: CGFloat = 0
        for word in words {
            let wordWidth = ceil((word as NSString).size(withAttributes: [.font: font]).width) + LiveStreamLayout.tokenPadding
            if x > 0 && x + wordWidth > width {
                lines += 1
                x = wordWidth
            } else {
                x += wordWidth
            }
        }
        return lines
    }
}
