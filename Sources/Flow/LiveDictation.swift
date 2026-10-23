import Foundation

struct LiveDictationOutcome {
    var raw: String
    var text: String
    var pasted: Bool
    var inserted: Bool
}

private struct TickCursor {
    /// Byte-Position im PCM, ab der noch kein Satz übergeben wurde.
    var audioOffset = 0
    /// Ob `audioOffset` aus Wortzeiten stammt (dann gibt es keinen Überlapp zu bereinigen).
    var exact = false
    var lastFresh: [String] = []
    var lastTickBytes = 0
}

/// Partial-ASR während der Aufnahme. Fertige Sätze werden einzeln korrigiert und eingefügt.
///
/// Erkennung, Korrektur und Animation laufen getrennt: Die Erkennung tickt alle ~0,25 s Audio,
/// jede Korrektur startet sofort und parallel, nur Anzeige und Einfügen laufen in Satzreihenfolge.
/// Alle Methoden laufen auf dem Hauptthread.
final class LiveDictation {
    var onCard: (() -> Void)?

    private let recorder: AudioRecorder
    private let engine: SpeechEngine
    private let inserter: TextInserter
    private let stream: LiveStreamModel?
    private let configProvider: () -> FlowConfig
    private let isCurrent: () -> Bool

    private var loop: Task<Void, Never>?
    private var playChain: Task<Void, Never>?
    private var stopFlag = false
    private var cancelFlag = false
    private var resumed = false
    private var finishContinuation: CheckedContinuation<LiveDictationOutcome, Never>?
    private var reservedRaw = ""
    private var committedText = ""
    private var inserted = false
    private var allPasted = true
    private var failStreak = 0
    private var degraded = false
    private let bytesPerSecond = 32_000
    /// Nur ohne Wortzeiten: so viel Audio wird vor dem Schnitt wiederholt, damit kein Wort fehlt.
    private let overlapBytes = 16_000
    private let tickBytes = 8_000

    init(
        recorder: AudioRecorder,
        engine: SpeechEngine,
        inserter: TextInserter,
        stream: LiveStreamModel?,
        configProvider: @escaping () -> FlowConfig,
        isCurrent: @escaping () -> Bool
    ) {
        self.recorder = recorder
        self.engine = engine
        self.inserter = inserter
        self.stream = stream
        self.configProvider = configProvider
        self.isCurrent = isCurrent
    }

    func start() {
        guard loop == nil else { return }
        // Die Karte steht vom ersten Moment an da. Der Text erscheint, sobald er erkannt ist.
        if stream != nil { onCard?() }
        loop = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    @MainActor
    func finish() async -> LiveDictationOutcome {
        if resumed { return outcome() }
        recorder.freeze()
        stopFlag = true
        return await withCheckedContinuation { continuation in
            if self.resumed {
                continuation.resume(returning: self.outcome())
            } else {
                self.finishContinuation = continuation
            }
        }
    }

    /// Bricht offene Sätze ab. Schon eingefügter Text bleibt und wird zurückgegeben.
    func cancel() -> LiveDictationOutcome {
        cancelFlag = true
        stopFlag = true
        recorder.freeze()
        loop?.cancel()
        playChain?.cancel()
        return outcome()
    }

    @MainActor
    private func run() async {
        var cursor = TickCursor()
        while !cancelFlag && isCurrent() {
            let count = recorder.pcmByteCount()
            if stopFlag {
                await flush(&cursor, count: count)
                break
            }
            if count - cursor.lastTickBytes < tickBytes || count - cursor.audioOffset < tickBytes {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            cursor.lastTickBytes = count
            await tick(&cursor, count: count, flush: false)
        }
        if !cancelFlag {
            await playChain?.value
        }
        complete()
    }

    @MainActor
    private func flush(_ cursor: inout TickCursor, count: Int) async {
        let newAudio = count - cursor.lastTickBytes
        // Gerade erst ausgewertet: Das letzte Ergebnis gilt, ein weiterer Durchlauf würde nur warten.
        if newAudio < 4_800, !cursor.lastFresh.isEmpty {
            commit(words: cursor.lastFresh, flush: true)
            return
        }
        if count - cursor.audioOffset < 3_200 {
            if !cursor.lastFresh.isEmpty { commit(words: cursor.lastFresh, flush: true) }
            return
        }
        await tick(&cursor, count: count, flush: true)
    }

    @MainActor
    private func tick(_ cursor: inout TickCursor, count: Int, flush: Bool) async {
        var start = cursor.exact ? cursor.audioOffset : max(0, cursor.audioOffset - overlapBytes)
        let maxSlice = 20 * bytesPerSecond
        if count - start > maxSlice {
            start = max(0, count - maxSlice)
            cursor.audioOffset = max(cursor.audioOffset, start)
        }
        start &= ~1
        let pcm = recorder.snapshotPCM(from: start)
        guard let wav = recorder.wavIfUseful(pcm) else { return }
        let prompt = String(reservedRaw.suffix(500))
        let reply: (text: String, ends: [Double]?)
        do {
            let config = configProvider()
            reply = try await engine.transcribeTimed(
                wav: wav,
                language: config.language,
                port: config.port,
                prompt: prompt.isEmpty ? nil : prompt
            )
        } catch {
            Timing.mark("live transcribe failed")
            return
        }
        guard !cancelFlag, isCurrent() else { return }

        let trimmed = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = LiveText.tokens(trimmed)
        let fresh = LiveText.freshWords(transcript: trimmed, committed: reservedRaw, dedupe: !cursor.exact)
        let dropped = all.count - fresh.count
        let previous = cursor.lastFresh
        cursor.lastFresh = fresh

        let looseStable = LiveText.commonPrefixCount(fresh, previous, loose: true)
        let exactStable = LiveText.commonPrefixCount(fresh, previous, loose: false)
        let stableCount = flush ? fresh.count : looseStable
        // Ein Satz wird erst fest, wenn er in zwei Durchläufen gleich war.
        let boundary = flush ? fresh : Array(fresh.prefix(exactStable))
        let split = LiveText.sentences(in: boundary, flush: flush)

        stream?.setOpen(words: fresh, stableCount: stableCount)

        var consumed = 0
        for sentence in split.complete {
            consumed += sentence.count
            hand(sentence: sentence)
        }
        guard consumed > 0 else { return }

        // Position des letzten übergebenen Wortes im Audio.
        if let ends = reply.ends, ends.count == all.count, dropped + consumed - 1 < ends.count {
            let seconds = ends[dropped + consumed - 1]
            let bytes = start + Int(seconds * Double(bytesPerSecond)) + 640
            cursor.audioOffset = min(count, max(cursor.audioOffset, bytes)) & ~1
            cursor.exact = true
        } else {
            cursor.audioOffset = min(count, cursor.audioOffset + consumed * 7_000) & ~1
            cursor.exact = false
        }
        cursor.lastFresh = Array(fresh.dropFirst(consumed))
    }

    /// Nur für den Abschluss ohne neue Erkennung.
    @MainActor
    private func commit(words: [String], flush: Bool) {
        stream?.setOpen(words: words, stableCount: words.count)
        for sentence in LiveText.sentences(in: words, flush: flush).complete {
            hand(sentence: sentence)
        }
    }

    @MainActor
    private func hand(sentence words: [String]) {
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return }
        reservedRaw = reservedRaw.isEmpty ? text : reservedRaw + " " + text
        let sentenceID = stream?.closeSentence(wordCount: words.count)
        // Die Korrektur startet jetzt, nicht erst wenn der Satz an der Reihe ist.
        let polish = Task { @MainActor [weak self] () -> (text: String, failed: Bool) in
            guard let self else { return (text, true) }
            return await self.correct(text)
        }
        let previous = playChain
        playChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.cancelFlag, self.isCurrent() else {
                polish.cancel()
                return
            }
            let corrected = await polish.value
            guard !self.cancelFlag, self.isCurrent() else { return }
            let polishedWords = LiveText.tokens(corrected.text)
            if let stream = self.stream, let sentenceID {
                await stream.play(
                    sentenceID: sentenceID,
                    polishedWords: polishedWords.isEmpty ? words : polishedWords,
                    failed: corrected.failed
                ) { [weak self] in
                    self?.performInsert(corrected.failed ? text : corrected.text)
                }
            } else {
                self.performInsert(corrected.failed ? text : corrected.text)
            }
        }
    }

    @MainActor
    private func correct(_ sentence: String) async -> (text: String, failed: Bool) {
        let config = configProvider()
        guard config.autoCorrect, !degraded, engine.polishAvailable else {
            return (sentence, false)
        }
        do {
            let polished = try await engine.polish(raw: sentence, selection: nil, config: config)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if polished.isEmpty {
                noteFailure()
                return (sentence, true)
            }
            failStreak = 0
            return (polished, false)
        } catch {
            if cancelFlag || Task.isCancelled { return (sentence, true) }
            Timing.mark("live polish failed")
            noteFailure()
            return (sentence, true)
        }
    }

    private func noteFailure() {
        failStreak += 1
        guard failStreak >= 3 else { return }
        degraded = true
        stream?.degraded = true
    }

    private func performInsert(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty, !cancelFlag else { return }
        let result = inserter.insert(piece + " ")
        if committedText.isEmpty {
            committedText = piece
        } else {
            committedText += " " + piece
        }
        inserted = true
        if !result.pasted { allPasted = false }
        stream?.noteInserted(copied: !result.pasted)
        Timing.mark("live inserted (\(piece.count) chars, pasted=\(result.pasted))")
    }

    private func outcome() -> LiveDictationOutcome {
        LiveDictationOutcome(
            raw: reservedRaw,
            text: committedText,
            pasted: inserted && allPasted,
            inserted: inserted
        )
    }

    private func complete() {
        guard !resumed else { return }
        resumed = true
        recorder.discardBuffer()
        let outcome = outcome()
        finishContinuation?.resume(returning: outcome)
        finishContinuation = nil
    }
}
