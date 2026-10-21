import Cocoa
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let hotkeys = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private lazy var dictionaryLearner = DictionaryLearner(inserter: inserter)
    private let engine = SpeechEngine()
    private var overlay: OverlayController?
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var job: Task<Void, Never>?
    private var dictationGeneration = 0
    /// Reads the selection while the user is still speaking, so stop does not block on accessibility.
    private var selectionTask: Task<String?, Never>?
    private var listenStarted = Date()
    private var ticker: Timer?
    private var permissionTimer: Timer?
    private var resetWork: DispatchWorkItem?
    private var silenceWork: DispatchWorkItem?
    private var warmupTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var correctionLookup: Task<Void, Never>?
    private var correctionLookupKey: String?
    private var correctionGeneration = 0
    private var dictationApp: FrontApp?
    private var frontObserver: NSObjectProtocol?
    /// Rohdaten für die Auswahl Befehl vs. Umformulierung.
    private var pendingChoiceMeta: (raw: String, duration: TimeInterval, app: String?)?

    private func clearDictationPreview() {
        state.dictationPreview = nil
    }

    private func presentDictationPreview(
        text: String,
        status: DictationPreviewStatus,
        wasCommand: Bool = false
    ) {
        guard state.config.showDictationPreview else {
            clearDictationPreview()
            return
        }
        state.dictationPreview = DictationPreview(text: text, status: status, wasCommand: wasCommand)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        inserter.onDisplacedClipboard = { [weak self] text in
            self?.state.rememberClipboard(text)
        }
        OutputSilence.recover()
        overlay = OverlayController(state: state)
        installEditMenu()
        setupStatusItem()
        wireState()
        startWarmupTimer()

        hotkeys.hotkey = state.config.resolvedHotkey
        updateLaunch(state.config.launchAtLogin)
        hotkeys.onPress = { [weak self] in self?.dismissTransient() }
        hotkeys.onHoldStart = { [weak self] in self?.beginListening(handsFree: false) }
        hotkeys.onHoldEnd = { [weak self] in
            guard let self, self.state.phase == .listening, !self.state.handsFree else { return }
            self.stopAndProcess()
        }
        hotkeys.onToggle = { [weak self] in self?.toggleHandsFree() }
        hotkeys.onEscape = { [weak self] in self?.cancel() }
        hotkeys.start()

        recorder.onLimit = { [weak self] in self?.stopAndProcess() }
        recorder.onLevel = { [weak self] level in
            guard let self, self.state.phase == .listening else { return }
            self.state.pushLevel(level)
        }
        engine.onUpdate = { [weak self] in
            guard let self else { return }
            let becameReady = !self.state.engineReady && self.engine.ready
            if self.state.engineReady != self.engine.ready { self.state.engineReady = self.engine.ready }
            if becameReady { self.refreshCorrectionModel(OpenAIKeyStore.load()) }
            if self.state.polishAvailable != self.engine.polishAvailable {
                self.state.polishAvailable = self.engine.polishAvailable
            }
            if self.state.engineStatus != self.engine.statusText { self.state.engineStatus = self.engine.statusText }
            if self.state.engineLoading != self.engine.statusIsLoading { self.state.engineLoading = self.engine.statusIsLoading }
        }
        engine.start()
        observeFrontApp()
        state.rescanApps()

        state.refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.state.axGranted
            self.state.refreshPermissions()
            if !before && self.state.axGranted {
                self.hotkeys.stop()
                self.hotkeys.start()
                self.overlay?.show()
            }
        }

        // Widget sofort sichtbar
        overlay?.show()

        if !state.config.onboarded {
            showOnboarding()
        } else if !state.hasPermissions {
            showMain(.home)
        }

        if !SnapshotMode.isActive {
            // Migrate signature-bound Keychain items once; later updates stay silent.
            DispatchQueue.global(qos: .utility).async {
                _ = OpenAIKeyStore.load()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.state.checkForUpdate()
            }
        }
    }

    /// Menüleisten-Apps haben sonst kein Menü „Bearbeiten“. Ohne den Eintrag
    /// kommt ⌘V in sicheren Textfeldern nicht an.
    private func installEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.s("edit.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.s("edit.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L10n.s("edit.menu"))
        editItem.submenu = edit
        edit.addItem(withTitle: L10n.s("edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L10n.s("edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.s("edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.s("edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.s("edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.s("edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseSilence()
        hotkeys.stop()
        ticker?.invalidate()
        permissionTimer?.invalidate()
        warmupTimer?.invalidate()
        warmupTimer = nil
        engine.shutdown()
    }

    /// Keeps Whisper weights in fast memory during idle gaps shorter than a cold reload.
    private func startWarmupTimer() {
        warmupTimer?.invalidate()
        warmupTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self, self.engine.ready, self.state.phase == .idle else { return }
            self.engine.prewarm(port: self.state.config.port)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain(nil)
        return true
    }

    // MARK: Wiring

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        updateIcon(.idle)

        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: MenuBarView().environmentObject(state))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    private func wireState() {
        state.toggleRecording = { [weak self] in self?.toggleHandsFree() }
        state.openMain = { [weak self] section in self?.showMain(section) }
        state.openNotes = { [weak self] in self?.openNotesFromMenu() }
        state.reloadEngine = { [weak self] in self?.engine.restart() }
        state.finishOnboarding = { [weak self] in
            self?.state.withoutSettingToast { self?.state.config.onboarded = true }
            self?.onboardingWindow?.close()
        }
        state.translateSelection = { [weak self] lang in self?.translateSelection(to: lang) }
        state.applyOverlayChoice = { [weak self] choice in self?.applyOverlayChoice(choice) }
        state.lookupCorrectionModel = { [weak self] key, base in self?.refreshCorrectionModel(key, baseURL: base) }
        state.configChanged = { [weak self] old, new in self?.configChanged(from: old, to: new) }
        state.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.updateIcon(phase) }
            .store(in: &cancellables)
        Publishers.CombineLatest(state.$update, state.$dismissedUpdate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.updateIcon(self.state.phase)
            }
            .store(in: &cancellables)
    }

    private func refreshCorrectionModel(_ key: String, baseURL: String? = nil) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseURL ?? self.state.config.resolvedCorrectionBaseURL
        let host = URL(string: base)?.host?.lowercased() ?? ""
        let needsKey = ["api.openai.com", "api.anthropic.com", "api.cursor.com"].contains(host)
        guard state.config.correctsWithOpenAI, !needsKey || !trimmed.isEmpty else {
            correctionGeneration += 1
            correctionLookup?.cancel()
            correctionLookupKey = nil
            state.correctionCatalogs[base] = CorrectionCatalog()
            state.correctionLookupErrors[base] = nil
            if state.config.resolvedCorrectionBaseURL == base {
                state.correctionModel = ""
                state.correctionModels = []
            }
            return
        }
        let token = "\(base)\n\(trimmed)"
        if correctionLookupKey == token, state.correctionCatalogs[base]?.recommended.isEmpty == false { return }
        correctionLookupKey = token
        correctionGeneration += 1
        let generation = correctionGeneration
        let port = state.config.port
        correctionLookup?.cancel()
        correctionLookup = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.engine.correctionModel(apiKey: trimmed, baseURL: base, port: port)
                await MainActor.run {
                    guard self.correctionGeneration == generation else { return }
                    let next = CorrectionCatalog(recommended: catalog.model, models: catalog.models ?? [])
                    self.state.correctionCatalogs[base] = next
                    self.state.correctionLookupErrors[base] = nil
                    self.state.correctionModel = next.recommended
                    self.state.correctionModels = next.models
                }
            } catch {
                await MainActor.run {
                    guard self.correctionGeneration == generation else { return }
                    self.correctionLookupKey = nil
                    self.state.correctionCatalogs[base] = CorrectionCatalog()
                    self.state.correctionLookupErrors[base] = error.localizedDescription
                    self.state.correctionModel = ""
                    self.state.correctionModels = []
                }
            }
        }
    }

    private func observeFrontApp() {
        if let app = FrontApp.current() {
            state.frontApp = app
            state.rememberApp(app)
        }
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { return }
            let raw = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let front = FrontApp(bundleID: id, name: raw.isEmpty ? id : raw)
            self.state.frontApp = front
            self.state.rememberApp(front)
        }
    }

    private func configChanged(from old: FlowConfig, to new: FlowConfig) {
        hotkeys.hotkey = new.resolvedHotkey
        if old.launchAtLogin != new.launchAtLogin {
            updateLaunch(new.launchAtLogin)
        }
        if old.modelPath != new.modelPath
            || old.whisperModel != new.whisperModel
            || old.asrEngine != new.asrEngine
            || old.asrQuality != new.asrQuality
            || old.port != new.port {
            engine.restart()
        }
        if old.othersAudio != new.othersAudio {
            releaseSilence()
            if state.phase == .listening {
                scheduleSilence()
            }
        }
        if old.learnEdits != new.learnEdits, !new.learnEdits {
            dictionaryLearner.stop()
        }
    }

    // MARK: Dictation

    private func scheduleSilence() {
        silenceWork?.cancel()
        let mode = state.config.othersAudioMode
        guard mode != .off, state.phase == .listening else {
            OutputSilence.end()
            return
        }
        let delay: TimeInterval = state.config.playSounds ? 0.18 : 0
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.phase == .listening else { return }
            let mode = self.state.config.othersAudioMode
            guard mode != .off else { return }
            OutputSilence.begin(mode)
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func releaseSilence() {
        silenceWork?.cancel()
        silenceWork = nil
        OutputSilence.end()
    }

    /// The confirmation banner swallows the next hold if it stays up. Drop it as soon as Fn goes down.
    private func dismissTransient() {
        if state.dictationPreview != nil {
            clearDictationPreview()
        }
        switch state.phase {
        case .done, .notice, .failed:
            show(.idle)
        default:
            break
        }
    }

    private func show(_ phase: Phase, resetAfter delay: TimeInterval? = nil) {
        resetWork?.cancel()
        switch phase {
        case .listening, .transcribing, .failed, .notice:
            clearDictationPreview()
        case .polishing(let raw):
            if state.config.showDictationPreview, !state.rewriting {
                presentDictationPreview(text: raw, status: .working)
            } else if state.rewriting {
                clearDictationPreview()
            }
        default:
            break
        }
        state.phase = phase
        guard let delay else { return }
        let work = DispatchWorkItem { [weak self] in self?.state.phase = .idle }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginListening(handsFree: Bool) {
        if case .listening = state.phase { return }
        guard engine.ready else {
            show(.notice(L10n.s("notice.loading")), resetAfter: 1.8)
            return
        }
        let microphone = Permissions.microphoneStatus()
        if microphone == .notDetermined {
            Permissions.requestMicrophone { [weak self] granted in
                DispatchQueue.main.async {
                    self?.state.refreshPermissions()
                    if granted { self?.beginListening(handsFree: handsFree) }
                }
            }
            return
        }
        guard microphone == .authorized else {
            show(.failed(L10n.s("notice.micDenied")), resetAfter: 2.2)
            showMain(.settings)
            return
        }
        // Ohne Bedienungshilfen: Aufnahme vom Widget geht, Einfügen wird zur Zwischenablage.
        // Die globale Taste braucht Bedienungshilfen – die prüft der HotkeyMonitor selbst.
        job?.cancel()
        selectionTask?.cancel()
        selectionTask = nil
        state.rewriting = false
        dictationGeneration += 1
        dictationApp = FrontApp.current()
        if let dictationApp { state.rememberApp(dictationApp) }
        inserter.rememberInsertTarget()
        engine.prewarm(port: state.config.port)
        do {
            try recorder.start(inputUID: state.config.inputDeviceUID)
        } catch {
            show(.failed(error.localizedDescription), resetAfter: 2.5)
            return
        }
        // Die Taste kann schon oben sein, während das Mikrofon (etwa AirPods) noch aufgeht.
        if !handsFree, !hotkeys.isHolding {
            _ = recorder.stop()
            return
        }
        startSelectionCapture()
        dictionaryLearner.stop()
        popover.performClose(nil)
        state.overlayResult = nil
        state.notePreview = nil
        clearDictationPreview()
        pendingChoiceMeta = nil
        state.handsFree = handsFree
        state.resetLevels()
        state.elapsed = 0
        listenStarted = Date()
        show(.listening)
        if state.config.playSounds { NSSound(named: "Tink")?.play() }
        scheduleSilence()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.state.phase == .listening else { return }
            self.state.elapsed = Date().timeIntervalSince(self.listenStarted)
        }
    }

    private func startSelectionCapture() {
        selectionTask?.cancel()
        // Markierung auch ohne bereite Korrektur lesen, damit ein Befehl nicht als Diktat darüberklebt.
        guard state.config.commandMode else {
            selectionTask = nil
            return
        }
        let inserter = self.inserter
        selectionTask = Task {
            await inserter.captureSelection()
        }
    }

    private func toggleHandsFree() {
        if state.phase == .listening {
            stopAndProcess()
        } else {
            beginListening(handsFree: true)
        }
    }

    private func cancel() {
        switch state.phase {
        case .listening:
            releaseSilence()
            selectionTask?.cancel()
            selectionTask = nil
            _ = recorder.stop()
            ticker?.invalidate()
            state.handsFree = false
            show(.notice(L10n.s("notice.cancelled")), resetAfter: 0.9)
        case .transcribing, .polishing, .translating:
            job?.cancel()
            selectionTask?.cancel()
            selectionTask = nil
            state.rewriting = false
            show(.notice(L10n.s("notice.cancelled")), resetAfter: 0.9)
        default:
            break
        }
    }

    private func stopAndProcess() {
        guard state.phase == .listening else { return }
        Timing.begin("---- recording stopped")
        releaseSilence()
        let wav = recorder.stop()
        let duration = Date().timeIntervalSince(listenStarted)
        state.handsFree = false
        ticker?.invalidate()
        if state.config.playSounds { NSSound(named: "Pop")?.play() }
        guard let wav else {
            selectionTask?.cancel()
            selectionTask = nil
            show(.notice(L10n.s("notice.nothingHeard")), resetAfter: 1.4)
            return
        }
        let modelAvailable = engine.polishAvailable
        let wantsSelection = state.config.commandMode
        let capture = selectionTask
        selectionTask = nil
        if !wantsSelection { capture?.cancel() }
        let front = FrontApp.current() ?? dictationApp
        if let front { state.rememberApp(front) }
        let appName = front?.name ?? inserter.frontmostAppName()
        var config = state.config
        if let front { config.style = state.effectiveStyle(for: front) }
        if !modelAvailable { config.autoCorrect = false }
        let snapshot = config
        show(.transcribing)
        let generation = dictationGeneration

        job = Task { [weak self] in
            guard let self else { return }
            let selectionLogged = Task { () -> String? in
                let value: String?
                if wantsSelection, let capture {
                    value = await capture.value
                } else {
                    value = nil
                }
                let detail = value == nil ? "none" : "\(value!.count) chars"
                Timing.mark("selection read (\(detail)), app=\(appName ?? "?"), style=\(snapshot.style)")
                return value
            }
            do {
                let raw = try await self.engine.transcribe(wav: wav, language: snapshot.language, port: snapshot.port)
                Timing.mark("whisper done (autoCorrect=\(snapshot.autoCorrect))")
                if Task.isCancelled || generation != self.dictationGeneration { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let selection = await selectionLogged.value
                guard !trimmed.isEmpty else {
                    await MainActor.run { self.show(.notice(L10n.s("notice.nothingRecognized")), resetAfter: 1.4) }
                    return
                }

                if let selection,
                   !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let noteKind = NoteSaveCommand.kind(trimmed) {
                    let marked = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch noteKind {
                    case .verbatim:
                        _ = await self.state.saveCapturedText(marked)
                        Timing.mark("note command saved verbatim")
                        await MainActor.run {
                            guard generation == self.dictationGeneration else { return }
                            self.finishNoteSave(
                                body: marked,
                                spoken: trimmed,
                                duration: duration,
                                app: appName
                            )
                        }
                    case .answer:
                        guard modelAvailable else {
                            await MainActor.run {
                                guard generation == self.dictationGeneration else { return }
                                self.show(.notice(L10n.s("notice.commandNeedsKey")), resetAfter: 2.8)
                            }
                            return
                        }
                        await MainActor.run {
                            guard generation == self.dictationGeneration else { return }
                            self.state.rewriting = true
                            self.show(.polishing(raw: trimmed))
                        }
                        Timing.mark("note command answer")
                        let answer: String
                        do {
                            answer = try await self.engine.polish(
                                raw: trimmed,
                                selection: marked,
                                config: snapshot,
                                noteAnswer: true
                            ).trimmingCharacters(in: .whitespacesAndNewlines)
                        } catch {
                            if Task.isCancelled || generation != self.dictationGeneration { return }
                            let failure = error.localizedDescription
                            await MainActor.run {
                                guard generation == self.dictationGeneration else { return }
                                self.state.rewriting = false
                                self.show(.failed(failure), resetAfter: 3.2)
                            }
                            return
                        }
                        if Task.isCancelled || generation != self.dictationGeneration { return }
                        guard !answer.isEmpty else {
                            await MainActor.run {
                                guard generation == self.dictationGeneration else { return }
                                self.state.rewriting = false
                                self.show(.failed(L10n.s("notice.commandFailed")), resetAfter: 3.2)
                            }
                            return
                        }
                        _ = await self.state.saveCapturedText(answer)
                        Timing.mark("note command saved answer")
                        await MainActor.run {
                            guard generation == self.dictationGeneration else { return }
                            self.finishNoteSave(
                                body: answer,
                                spoken: trimmed,
                                duration: duration,
                                app: appName
                            )
                        }
                    }
                    return
                }

                if let selection, !selection.isEmpty, !modelAvailable {
                    await MainActor.run {
                        guard generation == self.dictationGeneration else { return }
                        self.show(.notice(L10n.s("notice.commandNeedsKey")), resetAfter: 2.8)
                    }
                    return
                }

                // Nur Whisper: direkt einfügen, kein Sprachmodell.
                if !snapshot.autoCorrect && selection == nil {
                    await MainActor.run {
                        guard generation == self.dictationGeneration else { return }
                        Timing.mark("main thread reached")
                        self.deliver(text: trimmed, raw: trimmed, duration: duration, app: appName, command: false)
                        self.inserter.logWhenLanded(trimmed)
                    }
                    return
                }

                // Remote correction starts now, so the round trip overlaps the paste.
                // A local model waits until the paste has landed, otherwise it occupies the GPU.
                let remote = snapshot.polishProvider != "local"

                // Sofort einfügen – außer bei Bearbeitungsbefehl / Umformulierung auf Markierung.
                if selection == nil {
                    let polishTask: Task<String, Error>? = remote
                        ? Task { try await self.engine.polish(raw: trimmed, selection: nil, config: snapshot) }
                        : nil
                    if polishTask != nil { Timing.mark("polish request sent") }

                    let earlyResult = await MainActor.run { () -> InsertResult in
                        Timing.mark("main thread reached")
                        self.show(.polishing(raw: trimmed))
                        let result = self.inserter.insert(trimmed)
                        self.inserter.logWhenLanded(trimmed)
                        return result
                    }

                    guard !Task.isCancelled, generation == self.dictationGeneration else {
                        polishTask?.cancel()
                        return
                    }

                    let activePolish: Task<String, Error>
                    if let polishTask {
                        activePolish = polishTask
                    } else {
                        try? await Task.sleep(nanoseconds: 40_000_000)
                        Timing.mark("polish request sent")
                        activePolish = Task { try await self.engine.polish(raw: trimmed, selection: nil, config: snapshot) }
                    }

                    var polishedText = trimmed
                    var polishError: String?
                    do {
                        let polished = try await activePolish.value
                        let clean = polished.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { polishedText = clean }
                    } catch {
                        if Task.isCancelled || generation != self.dictationGeneration { return }
                        polishError = error.localizedDescription
                    }
                    if Task.isCancelled || generation != self.dictationGeneration { return }
                    let final = polishedText
                    let correctionError = polishError

                    await MainActor.run {
                        guard generation == self.dictationGeneration else { return }
                        var landed = final
                        if final != trimmed, earlyResult.pasted,
                           !self.inserter.replacePreviousInsert(raw: trimmed, with: final) {
                            landed = trimmed
                        } else if final != trimmed, !earlyResult.pasted {
                            self.inserter.copyToClipboard(final)
                        } else if final == trimmed, earlyResult.keptOnClipboard {
                            self.inserter.copyToClipboard(final)
                        }
                        self.finishDeliver(
                            text: final,
                            raw: trimmed,
                            duration: duration,
                            app: appName,
                            command: false,
                            pasted: earlyResult.pasted,
                            fieldText: earlyResult.pasted ? landed : nil
                        )
                        if let correctionError {
                            self.show(.notice(correctionError), resetAfter: 3.4)
                        }
                    }
                    return
                }

                // Markierung: immer fragen, ob Befehl oder Umformulierung.
                await MainActor.run {
                    guard generation == self.dictationGeneration else { return }
                    self.state.rewriting = true
                    self.show(.polishing(raw: trimmed))
                }

                Timing.mark("choice polish (command + reformulate)")
                async let commandPolish = self.engine.polish(raw: trimmed, selection: selection, config: snapshot)
                async let rewritePolish = self.engine.polish(raw: trimmed, selection: nil, config: snapshot)
                var commandText = ""
                var rewriteText = ""
                var polishError: String?
                do {
                    commandText = try await commandPolish.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    if Task.isCancelled || generation != self.dictationGeneration { return }
                    polishError = error.localizedDescription
                }
                do {
                    rewriteText = try await rewritePolish.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    if Task.isCancelled || generation != self.dictationGeneration { return }
                    if polishError == nil { polishError = error.localizedDescription }
                }
                if Task.isCancelled || generation != self.dictationGeneration { return }
                if commandText.isEmpty, rewriteText.isEmpty {
                    let failure = polishError
                    await MainActor.run {
                        guard generation == self.dictationGeneration else { return }
                        self.state.rewriting = false
                        self.show(.failed(failure ?? L10n.s("notice.commandFailed")), resetAfter: 3.2)
                    }
                    return
                }
                if commandText.isEmpty { commandText = trimmed }
                if rewriteText.isEmpty { rewriteText = trimmed }
                let commandChoice = commandText
                let rewriteChoice = rewriteText

                await MainActor.run {
                    guard generation == self.dictationGeneration else { return }
                    self.deliverSelectionOutcome(
                        spoken: trimmed,
                        selection: selection!,
                        intent: .ambiguous,
                        commandText: commandChoice,
                        rewriteText: rewriteChoice,
                        duration: duration,
                        app: appName
                    )
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { self.show(.failed(error.localizedDescription), resetAfter: 3) }
            }
        }
    }

    private func finishNoteSave(
        body: String,
        spoken: String,
        duration: TimeInterval,
        app: String?
    ) {
        state.rewriting = false
        state.addHistory(HistoryEntry(
            id: UUID(),
            date: Date(),
            raw: spoken,
            text: body,
            duration: duration,
            app: app,
            wasCommand: true
        ))
        show(.idle)
    }

    private func deliverSelectionOutcome(
        spoken: String,
        selection: String,
        intent: SelectionIntent,
        commandText: String?,
        rewriteText: String?,
        duration: TimeInterval,
        app: String?
    ) {
        _ = selection
        switch intent {
        case .ambiguous:
            let command = commandText ?? spoken
            let rewrite = rewriteText ?? spoken
            pendingChoiceMeta = (spoken, duration, app)
            state.rewriting = false
            state.overlayResult = OverlayResult(
                command: spoken,
                text: command,
                choices: [
                    OverlayResultChoice(
                        kind: .command,
                        title: L10n.s("overlay.choice.command"),
                        text: command
                    ),
                    OverlayResultChoice(
                        kind: .reformulate,
                        title: L10n.s("overlay.choice.reformulate"),
                        text: rewrite
                    ),
                ]
            )
            state.widgetHovered = true
            state.widgetTranslateOpen = false
            show(.idle)

        case .command:
            let text = commandText ?? spoken
            applySelectionText(text, spoken: spoken, duration: duration, app: app, asCommand: true)

        case .reformulate:
            let text = rewriteText ?? spoken
            applySelectionText(text, spoken: spoken, duration: duration, app: app, asCommand: false)
        }
    }

    private func applySelectionText(
        _ text: String,
        spoken: String,
        duration: TimeInterval,
        app: String?,
        asCommand: Bool
    ) {
        if !inserter.hasInsertableFocus() {
            presentOverlayResult(
                command: spoken,
                text: text,
                raw: spoken,
                duration: duration,
                app: app,
                wasCommand: asCommand
            )
            return
        }
        let result = inserter.insert(text)
        finishDeliver(
            text: text,
            raw: spoken,
            duration: duration,
            app: app,
            command: asCommand,
            pasted: result.pasted,
            fieldText: result.pasted ? text : nil
        )
    }

    private func applyOverlayChoice(_ choice: OverlayResultChoice) {
        let meta = pendingChoiceMeta
        pendingChoiceMeta = nil
        state.overlayResult = nil
        overlay?.releaseKey()
        let spoken = meta?.raw ?? choice.text
        let duration = meta?.duration ?? 0
        let app = meta?.app
        inserter.insertAtRememberedCursor(choice.text, fallbackBundleID: dictationApp?.bundleID) { [weak self] result in
            guard let self else { return }
            self.finishDeliver(
                text: choice.text,
                raw: spoken,
                duration: duration,
                app: app,
                command: choice.kind == .command,
                pasted: result.pasted,
                fieldText: result.pasted ? choice.text : nil
            )
        }
    }

    private func translateSelection(to languageId: String) {
        guard !state.isBusy else { return }
        guard engine.ready else {
            show(.notice(L10n.s("notice.loading")), resetAfter: 1.6)
            return
        }
        guard engine.polishAvailable else {
            let hint = state.config.usesCustomCorrectionAPI
                ? L10n.s("notice.translateNeedsModel")
                : state.config.correctsWithOpenAI
                    ? L10n.s("notice.translateNeedsKey")
                    : L10n.s("notice.translateNeedsModel")
            show(.notice(hint), resetAfter: 2.2)
            return
        }
        let lang = TranslateLanguage.named(languageId)
        let snapshot = state.config
        show(.translating(code: lang.id))
        state.widgetHovered = true
        state.widgetTranslateOpen = false

        job = Task { [weak self] in
            guard let self else { return }
            guard let selection = await self.inserter.captureSelection(), !selection.isEmpty else {
                await MainActor.run { self.show(.notice(L10n.s("notice.selectFirst")), resetAfter: 1.6) }
                return
            }
            do {
                let translated = try await self.engine.polish(
                    raw: selection,
                    selection: selection,
                    config: snapshot,
                    targetLanguage: languageId
                )
                if Task.isCancelled { return }
                let text = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    await MainActor.run { self.show(.failed(L10n.s("notice.noTranslation")), resetAfter: 2) }
                    return
                }
                await MainActor.run {
                    if !self.inserter.hasInsertableFocus() {
                        self.presentOverlayResult(
                            command: L10n.s("overlay.translate"),
                            text: text,
                            raw: selection,
                            duration: nil,
                            app: self.inserter.frontmostAppName()
                        )
                        return
                    }
                    let result = self.inserter.insert(text)
                    self.state.addHistory(HistoryEntry(
                        id: UUID(),
                        date: Date(),
                        raw: selection,
                        text: text,
                        duration: nil,
                        app: self.inserter.frontmostAppName(),
                        wasCommand: true
                    ))
                    if self.state.config.showDictationPreview {
                        if result.pasted {
                            self.clearDictationPreview()
                        } else {
                            self.presentDictationPreview(
                                text: text,
                                status: .copied,
                                wasCommand: true
                            )
                        }
                        self.show(.idle)
                    } else {
                        self.show(
                            .done(text: text, pasted: result.pasted),
                            resetAfter: result.pasted ? 0.85 : 2.2
                        )
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { self.show(.failed(error.localizedDescription), resetAfter: 3) }
            }
        }
    }

    private func presentOverlayResult(
        command: String,
        text: String,
        raw: String,
        duration: TimeInterval?,
        app: String?,
        wasCommand: Bool = true
    ) {
        state.rewriting = false
        clearDictationPreview()
        state.overlayResult = OverlayResult(command: command, text: text)
        state.widgetHovered = true
        state.widgetTranslateOpen = false
        state.addHistory(HistoryEntry(
            id: UUID(),
            date: Date(),
            raw: raw,
            text: text,
            duration: duration,
            app: app,
            wasCommand: wasCommand
        ))
        show(.idle)
    }

    private func finishDeliver(
        text: String,
        raw: String,
        duration: TimeInterval,
        app: String?,
        command: Bool,
        pasted: Bool,
        fieldText: String? = nil
    ) {
        state.rewriting = false
        state.addHistory(HistoryEntry(
            id: UUID(),
            date: Date(),
            raw: raw,
            text: text,
            duration: duration,
            app: app,
            wasCommand: command
        ))
        if state.config.showDictationPreview {
            if pasted {
                // Insert succeeded — drop the preview without morphing to a countdown bar.
                clearDictationPreview()
            } else {
                presentDictationPreview(
                    text: text,
                    status: .copied,
                    wasCommand: command
                )
            }
            show(.idle)
        } else {
            show(.done(text: text, pasted: pasted), resetAfter: pasted ? 0.85 : 2.2)
        }
        guard let fieldText, state.config.learnEdits else { return }
        dictionaryLearner.watch(inserted: fieldText) { [weak self] items in
            self?.applyLearned(items)
        }
    }

    private func applyLearned(_ learned: [DictionaryItem]) {
        var items = DictionaryItem.parse(state.config.dictionary)
        var added: [DictionaryItem] = []
        for item in learned where item.isKept {
            let exists = items.contains {
                $0.term.caseInsensitiveCompare(item.term) == .orderedSame
                    && $0.heardAs.caseInsensitiveCompare(item.heardAs) == .orderedSame
            }
            guard !exists else { continue }
            items.insert(item, at: 0)
            added.append(item)
        }
        guard !added.isEmpty else { return }
        state.withoutSettingToast {
            state.config.dictionary = DictionaryItem.serialize(items)
        }
        let summary = added.prefix(3).map { item in
            item.heardAs.isEmpty ? item.term : "\(item.heardAs) → \(item.term)"
        }.joined(separator: ", ")
        switch state.phase {
        case .listening, .transcribing, .polishing, .translating:
            break
        default:
            show(.notice(L10n.s("dictionary.learned", summary)), resetAfter: 2.4)
        }
    }

    private func deliver(text: String, raw: String, duration: TimeInterval, app: String?, command: Bool) {
        let result = inserter.insert(text)
        finishDeliver(
            text: text,
            raw: raw,
            duration: duration,
            app: app,
            command: command,
            pasted: result.pasted,
            fieldText: result.pasted ? text : nil
        )
    }

    // MARK: Windows

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Fresh check when the menu opens; show an offer, do not install yet.
            state.checkForUpdate(autoInstall: false)
        }
    }

    private func openNotesFromMenu() {
        popover.performClose(nil)
        guard let folder = AppleNotesFolder.decode(state.config.noteDestination) else {
            showMain(.notes)
            return
        }
        let noteID = AppleNotes.rememberedID()
        Task {
            do {
                try await AppleNotes.reveal(account: folder.account, folder: folder.name, noteID: noteID)
            } catch {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
            }
        }
    }

    private func showMain(_ section: MainSection?) {
        if let section { state.section = section }
        popover.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.appName
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 920, height: 620)
            window.contentView = NSHostingView(rootView: MainView().environmentObject(state))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("FlowMainWindow")
            mainWindow = window
        }
        present(mainWindow)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.s("onboarding.welcome")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView().environmentObject(state))
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            if !state.config.onboarded {
                state.withoutSettingToast { state.config.onboarded = true }
            }
            onboardingWindow = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let visible = [self.mainWindow, self.onboardingWindow].contains { $0?.isVisible == true }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func updateLaunch(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            show(.failed(L10n.s("notice.login", error.localizedDescription)), resetAfter: 3)
        }
    }

    private func updateIcon(_ phase: Phase) {
        guard let button = statusItem?.button else { return }
        let listening = phase == .listening
        let symbol: String
        switch phase {
        case .transcribing, .polishing, .translating:
            symbol = "ellipsis.circle"
        default:
            symbol = "waveform"
        }
        let badge = state.showsUpdateOffer && symbol == "waveform"
        button.image = menuImage(symbol: symbol, badge: badge, tint: listening ? .systemOrange : nil)
        button.contentTintColor = nil
        button.setAccessibilityLabel(menuIconLabel(listening: listening, badge: badge))
        statusItem.length = badge ? 32 : NSStatusItem.squareLength
    }

    private func menuIconLabel(listening: Bool, badge: Bool) -> String {
        switch (listening, badge) {
        case (true, true): return L10n.s("status.icon.both")
        case (true, false): return L10n.s("status.icon.recording")
        case (false, true): return L10n.s("status.icon.update")
        case (false, false): return L10n.s("status.icon")
        }
    }

    /// Menu-bar glyph. Idle stays a template so it follows light and dark. Recording is painted orange.
    private func menuImage(symbol: String, badge: Bool, tint: NSColor?) -> NSImage {
        let width: CGFloat = badge ? 24 : 18
        let height: CGFloat = 18
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: badge ? 12 : 14, weight: .semibold)
            if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let side: CGFloat = badge ? 14 : 16
                let y = (rect.height - side) / 2
                base.draw(in: NSRect(x: 0, y: y, width: side, height: side))
            }
            if badge,
               let arrow = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) {
                arrow.draw(in: NSRect(x: rect.width - 9, y: rect.height - 9, width: 8, height: 8))
            }
            return true
        }
        guard let tint else {
            image.isTemplate = true
            return image
        }
        let colored = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        colored.isTemplate = false
        return colored
    }
}
