import AVFoundation
import Cocoa
import Combine
import Darwin

enum Phase: Equatable {
    case idle
    case listening
    case transcribing
    case polishing(raw: String)
    case translating(code: String)
    case done(text: String, pasted: Bool)
    case failed(String)
    case notice(String)
}

enum DictationPreviewStatus: Equatable {
    case working
    case inserted
    case copied
}

struct DictationPreview: Equatable {
    var text: String
    var status: DictationPreviewStatus
    /// false = normales Diktat; true = Befehl/Umformulierung auf Markierung.
    var wasCommand: Bool = false
}

enum EngineState {
    case ready
    case loading
    case error
}

enum MainSection: String, CaseIterable, Identifiable {
    case home
    case commands
    case history
    case notes
    case style
    case dictionary
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L10n.s("nav.home")
        case .commands: return L10n.s("nav.commands")
        case .history: return L10n.s("nav.history")
        case .notes: return L10n.s("nav.notes")
        case .style: return L10n.s("nav.style")
        case .dictionary: return L10n.s("nav.dictionary")
        case .settings: return L10n.s("nav.settings")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .commands: return "wand.and.stars"
        case .history: return "clock.arrow.circlepath"
        case .notes: return "note.text"
        case .style: return "textformat"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

final class AppState: ObservableObject {
    static let levelCount = 24

    @Published var phase: Phase = .idle
    /// True while a spoken command is rewriting a selection, so the widget does not show the command itself.
    @Published var rewriting = false
    @Published var levels: [CGFloat] = Array(repeating: 0, count: AppState.levelCount)
    @Published var elapsed: TimeInterval = 0
    @Published var handsFree = false
    @Published var engineReady = false
    @Published var polishAvailable = true
    @Published var correctionModel = ""
    @Published var correctionModels: [String] = []
    @Published var correctionCatalogs: [String: CorrectionCatalog] = [:]
    /// Letzter Fehler beim Laden der Modellliste, Schlüssel ist die API-Basisadresse.
    @Published var correctionLookupErrors: [String: String] = [:]
    @Published var frontApp: FrontApp?
    @Published var engineStatus = L10n.s("engine.loadingModel")
    @Published var engineLoading = true
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var widgetHovered = false
    @Published var widgetTranslateOpen = false
    @Published var overlayResult: OverlayResult?
    @Published var dictationPreview: DictationPreview?
    /// Flow Stream: Karte über dem Widget, solange die Live-Session läuft.
    @Published var liveStreamActive = false
    let liveStream = LiveStreamModel()
    @Published var notePreview: SavedNotePreview?
    /// Notiz, die die Notizen-Seite nach dem Öffnen auswählen soll.
    @Published var noteToOpen: UUID?
    @Published var widgetDragging = false
    @Published var section: MainSection = .home
    @Published var update: UpdateStatus = .idle
    @Published var dismissedUpdate = false
    @Published var config: FlowConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()
            configChanged?(oldValue, config)
            if oldValue.historyKeepHours != config.historyKeepHours
                || oldValue.historyMaxEntries != config.historyMaxEntries {
                pruneHistory()
            }
            if settingToastSuppressed == 0 {
                noteSettingChanged()
            }
        }
    }
    /// Unten im Fenster, sobald eine Einstellung gespeichert wurde.
    @Published var settingToastVisible = false
    @Published private(set) var settingToastToken = UUID()
    private var settingToastSuppressed = 0
    private var settingToastHide: DispatchWorkItem?
    @Published private(set) var history: [HistoryEntry]
    @Published private(set) var notes: [FlowNote]
    @Published var appleNoteFolders: [AppleNotesFolder] = []
    @Published var appleNotesStatus: String?

    var configChanged: ((FlowConfig, FlowConfig) -> Void)?
    var toggleRecording: () -> Void = {}
    var openMain: (MainSection?) -> Void = { _ in }
    var openNotes: () -> Void = {}
    var reloadEngine: () -> Void = {}
    var lookupCorrectionModel: (String, String) -> Void = { _, _ in }
    var finishOnboarding: () -> Void = {}
    var translateSelection: (String) -> Void = { _ in }
    var applyOverlayChoice: ((OverlayResultChoice) -> Void)?
    private var updateTask: Task<Void, Never>?

    init() {
        let loadedConfig = FlowConfig.load()
        let loaded = HistoryStore.load()
        let trimmed = loadedConfig.trimmedHistory(loaded)
        history = trimmed
        notes = NoteStore.load()
        config = loadedConfig
        if trimmed.count != loaded.count {
            HistoryStore.save(trimmed)
        }
    }

    func selectOverlayChoice(_ choice: OverlayResultChoice) {
        overlayResult = nil
        applyOverlayChoice?(choice)
    }

    var isBusy: Bool {
        switch phase {
        case .listening, .transcribing, .polishing, .translating: return true
        default: return false
        }
    }

    var engineState: EngineState {
        if engineReady { return .ready }
        return engineLoading ? .loading : .error
    }

    var modelDisplayName: String {
        switch config.asrEngine {
        case "whistle":
            return L10n.s("model.whistle.depth", config.whistleDepth)
        case "parakeet":
            return L10n.s("model.parakeet")
        case "qwen3":
            return L10n.s("model.qwen3")
        default:
            let id = config.resolvedWhisperModel.split(separator: "/").last.map(String.init) ?? L10n.s("model.local")
            return L10n.s("model.whisper", id)
        }
    }

    func rememberApp(_ app: FrontApp) {
        withoutSettingToast {
            if let index = config.appStyles.firstIndex(where: { $0.bundleID == app.bundleID }) {
                if config.appStyles[index].name != app.name {
                    config.appStyles[index].name = app.name
                }
                return
            }
            let suggested = AppStyleCatalog.suggest(bundleID: app.bundleID, name: app.name)
            config.appStyles.append(
                AppStyleProfile(
                    bundleID: app.bundleID,
                    name: app.name,
                    style: suggested,
                    suggested: suggested,
                    customized: false
                )
            )
            config.appStyles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func mergeInstalledApps(_ apps: [FrontApp]) {
        var next = config.appStyles
        var indexByID: [String: Int] = [:]
        for (index, profile) in next.enumerated() {
            indexByID[profile.bundleID] = index
        }
        var changed = false
        for app in apps {
            let suggested = AppStyleCatalog.suggest(bundleID: app.bundleID, name: app.name)
            if let index = indexByID[app.bundleID] {
                if next[index].name != app.name {
                    next[index].name = app.name
                    changed = true
                }
                if !next[index].customized, next[index].suggested != suggested {
                    next[index].suggested = suggested
                    next[index].style = suggested
                    changed = true
                }
            } else {
                next.append(
                    AppStyleProfile(
                        bundleID: app.bundleID,
                        name: app.name,
                        style: suggested,
                        suggested: suggested,
                        customized: false
                    )
                )
                indexByID[app.bundleID] = next.count - 1
                changed = true
            }
        }
        guard changed else { return }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        withoutSettingToast { config.appStyles = next }
    }

    /// Programm schreibt die Konfiguration, ohne den Speicher-Toast.
    func withoutSettingToast(_ body: () -> Void) {
        settingToastSuppressed += 1
        body()
        settingToastSuppressed -= 1
    }

    /// Kurzer Hinweis unten, dass die letzte Änderung liegt.
    func noteSettingChanged() {
        guard settingToastSuppressed == 0, !SnapshotMode.isActive else { return }
        if !settingToastVisible {
            settingToastToken = UUID()
            settingToastVisible = true
        }
        settingToastHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settingToastVisible = false
        }
        settingToastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    func setAppStyle(bundleID: String, name: String, style: String) {
        rememberApp(FrontApp(bundleID: bundleID, name: name))
        guard let index = config.appStyles.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        var profile = config.appStyles[index]
        profile.style = style
        profile.customized = style != profile.suggested
        guard config.appStyles[index] != profile else { return }
        config.appStyles[index] = profile
    }

    func effectiveStyle(for app: FrontApp) -> String {
        if let profile = config.appStyles.first(where: { $0.bundleID == app.bundleID }) {
            return profile.effectiveStyle
        }
        return AppStyleCatalog.suggest(bundleID: app.bundleID, name: app.name)
    }

    func previewHistory(_ entries: [HistoryEntry]) {
        guard SnapshotMode.isActive else { return }
        history = entries
    }

    func rescanApps() {
        if SnapshotMode.isActive { return }
        let running = FrontApp.running()
        DispatchQueue.global(qos: .utility).async {
            let installed = AppStyleCatalog.unify(AppStyleCatalog.installedApps() + running)
            DispatchQueue.main.async { [weak self] in
                self?.mergeInstalledApps(installed)
            }
        }
    }

    var hasPermissions: Bool { micGranted && axGranted }

    var availableRelease: AppRelease? {
        switch update {
        case .available(let release), .downloading(let release):
            return release
        default:
            return nil
        }
    }

    var isDownloadingUpdate: Bool {
        if case .downloading = update { return true }
        return false
    }

    var showsUpdateOffer: Bool {
        availableRelease != nil && !dismissedUpdate
    }

    /// `autoInstall` defaults to background checks (launch): offer and install.
    /// Menu and Settings pass `false` so the user sees the offer first.
    func checkForUpdate(userInitiated: Bool = false, autoInstall: Bool? = nil) {
        guard !SnapshotMode.isActive else { return }
        if case .downloading = update { return }
        let install = autoInstall ?? !userInitiated
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            await self?.performUpdateCheck(userInitiated: userInitiated, autoInstall: install)
        }
    }

    func installAvailableUpdate() {
        guard case .available = update else { return }
        updateTask?.cancel()
        beginUpdate()
    }

    func dismissUpdate() {
        guard case .available(let release) = update else { return }
        updateTask?.cancel()
        UpdateCheck.dismissedVersion = release.version
        dismissedUpdate = true
    }

    func openUpdatePage() {
        NSWorkspace.shared.open(UpdateCheck.page)
    }

    @MainActor
    private func performUpdateCheck(userInitiated: Bool, autoInstall: Bool) async {
        let previous = update
        update = .checking
        do {
            let release = try await UpdateCheck.fetch()
            guard !Task.isCancelled else { return }
            if UpdateCheck.isNewer(release.version, than: L10n.appVersion) {
                dismissedUpdate = UpdateCheck.dismissedVersion == release.version
                update = .available(release)
                if autoInstall, !dismissedUpdate {
                    beginUpdate()
                }
            } else {
                update = .current
            }
        } catch {
            guard !Task.isCancelled else { return }
            if userInitiated {
                update = .failed
            } else if case .available = previous {
                update = previous
            } else {
                update = .idle
            }
        }
    }

    private func beginUpdate() {
        guard case .available(let release) = update else { return }
        updateTask = Task { @MainActor in
            while phase != .idle {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if Task.isCancelled { return }
            await performInstall(release)
        }
    }

    @MainActor
    private func performInstall(_ release: AppRelease) async {
        update = .downloading(release)
        let hudPid = UpdateProgressHud.spawnDetached(version: release.version)
        do {
            let pkg = try await UpdateCheck.download(release)
            guard !Task.isCancelled else {
                if let hudPid { kill(hudPid, SIGTERM) }
                return
            }
            try await Task.detached(priority: .userInitiated) {
                try UpdateCheck.stageRelaunch(pkg: pkg, version: release.version)
            }.value
            NSApp.terminate(nil)
        } catch {
            if let hudPid { kill(hudPid, SIGTERM) }
            guard !Task.isCancelled else { return }
            update = .failed
        }
    }

    func pushLevel(_ value: CGFloat) {
        var next = levels
        next.removeFirst()
        next.append(value)
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: AppState.levelCount)
    }

    func refreshPermissions() {
        let mic = Permissions.microphoneStatus() == .authorized
        let ax = Permissions.accessibilityGranted()
        if mic != micGranted { micGranted = mic }
        if ax != axGranted { axGranted = ax }
    }

    func requestMicrophone() {
        if Permissions.microphoneStatus() == .notDetermined {
            Permissions.requestMicrophone { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        } else {
            Permissions.openMicrophoneSettings()
        }
    }

    func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    func addHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        history = config.trimmedHistory(history)
        HistoryStore.save(history)
    }

    func pruneHistory() {
        let next = config.trimmedHistory(history)
        guard next != history else { return }
        history = next
        HistoryStore.save(history)
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history.removeAll()
        HistoryStore.save(history)
    }

    @discardableResult
    func createNote() -> UUID {
        let now = Date()
        let note = FlowNote(id: UUID(), created: now, updated: now, title: "", body: "")
        notes.insert(note, at: 0)
        NoteStore.save(notes)
        return note.id
    }

    @discardableResult
    func addNote(body: String, title: String? = nil) -> UUID? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let resolved = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = FlowNote(
            id: UUID(),
            created: now,
            updated: now,
            title: (resolved?.isEmpty == false) ? resolved! : FlowNote.derivedTitle(from: trimmed),
            body: trimmed
        )
        notes.insert(note, at: 0)
        NoteStore.save(notes)
        return note.id
    }

    func updateNote(id: UUID, title: String, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].title != title || notes[index].body != body else { return }
        notes[index].title = title
        notes[index].body = body
        notes[index].updated = Date()
        NoteStore.save(notes)
    }

    func refreshAppleNoteFolders() {
        appleNotesStatus = L10n.s("notes.destination.loading")
        Task {
            do {
                let folders = try await AppleNotes.folders()
                await MainActor.run {
                    self.appleNoteFolders = folders
                    self.appleNotesStatus = folders.isEmpty ? L10n.s("notes.destination.none") : nil
                }
            } catch {
                await MainActor.run {
                    let denied = (error as? AppleNotesFailure)?.denied == true
                    self.appleNotesStatus = L10n.s(denied ? "notes.destination.denied" : "notes.destination.failed")
                }
            }
        }
    }

    func saveCapturedText(_ body: String) async -> NoteSaveOutcome {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .flow }
        let destination = await MainActor.run { self.config.noteDestination }
        if let folder = AppleNotesFolder.decode(destination) {
            do {
                let title = FlowNote.derivedTitle(from: trimmed)
                let noteID = try await AppleNotes.createNote(title: title, body: trimmed, account: folder.account, folder: folder.name)
                AppleNotes.remember(noteID)
                let preview = SavedNotePreview(
                    body: trimmed,
                    place: .apple(account: folder.account, folder: folder.name, noteID: noteID)
                )
                await MainActor.run { self.presentSavedNote(preview) }
                return .apple(folder: folder.name)
            } catch {
                let preview = await MainActor.run { () -> SavedNotePreview? in
                    guard let id = self.addNote(body: trimmed) else { return nil }
                    return SavedNotePreview(body: trimmed, place: .flow(id))
                }
                if let preview {
                    await MainActor.run { self.presentSavedNote(preview) }
                }
                return .fallback
            }
        }
        let preview = await MainActor.run { () -> SavedNotePreview? in
            guard let id = self.addNote(body: trimmed) else { return nil }
            return SavedNotePreview(body: trimmed, place: .flow(id))
        }
        if let preview {
            await MainActor.run { self.presentSavedNote(preview) }
        }
        return .flow
    }

    func presentSavedNote(_ preview: SavedNotePreview) {
        overlayResult = nil
        dictationPreview = nil
        notePreview = preview
    }

    func openSavedNote() {
        guard let preview = notePreview else { return }
        notePreview = nil
        switch preview.place {
        case .flow(let id):
            noteToOpen = id
            openMain(.notes)
        case .apple(let account, let folder, let noteID):
            Task {
                try? await AppleNotes.reveal(account: account, folder: folder, noteID: noteID)
            }
        }
    }

    func deleteNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
        NoteStore.save(notes)
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Previous clipboard contents, kept when dictation could not be inserted into a field.
    func rememberClipboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if history.first?.keepsClipboard == true, history.first?.text == text { return }
        addHistory(HistoryEntry(
            id: UUID(),
            date: Date(),
            raw: text,
            text: text,
            duration: nil,
            app: nil,
            wasCommand: nil,
            kind: "clipboard"
        ))
    }

    private var dictations: [HistoryEntry] {
        history.filter { !$0.keepsClipboard }
    }

    var totalWords: Int { dictations.reduce(0) { $0 + $1.words } }

    var todayCount: Int {
        dictations.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    // Tippgeschwindigkeit von 40 Wörtern pro Minute als Vergleichsbasis.
    var minutesSaved: Double {
        let typing = Double(totalWords) / 40
        let speaking = history.compactMap(\.duration).reduce(0, +) / 60
        return max(0, typing - speaking)
    }

    var speakingWPM: Int {
        let timed = history.filter { ($0.duration ?? 0) > 1 }
        let seconds = timed.compactMap(\.duration).reduce(0, +)
        guard seconds > 0 else { return 0 }
        let words = timed.reduce(0) { $0 + $1.words }
        return Int((Double(words) / (seconds / 60)).rounded())
    }
}
