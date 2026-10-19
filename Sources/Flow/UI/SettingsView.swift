import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    /// Drafts keyed by Keychain account (provider kind or custom UUID), not endpoint id.
    @State private var keyDrafts: [String: String] = [:]
    @State private var showAdvanced = false

    var body: some View {
        Page(title: L10n.s("settings.title"), subtitle: L10n.s("settings.subtitle")) {
            SettingsSection(title: L10n.s("settings.hotkey.section"), icon: "keyboard") {
                SettingRow(title: L10n.s("settings.hotkey.title"), detail: L10n.s("settings.hotkey.detail")) {
                    Picker("", selection: $state.config.hotkey) {
                        ForEach([Hotkey.function, .rightOption, .rightCommand, .rightControl, .leftControl], id: \.rawValue) { key in
                            Text(key.title).tag(key.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection(title: L10n.s("settings.language.section"), icon: "globe") {
                SettingRow(title: L10n.s("settings.native.title"), detail: L10n.s("settings.native.detail")) {
                    Picker("", selection: $state.config.nativeLanguage) {
                        ForEach(TranslateLanguage.all) { lang in
                            Text("\(lang.id.uppercased())  \(lang.name)").tag(lang.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                SettingRow(title: L10n.s("settings.recognition.title"), detail: recognitionDetail) {
                    if state.config.usesWhistle {
                        Picker("", selection: $state.config.language) {
                            ForEach(FlowConfig.whistleLanguages, id: \.self) { code in
                                Text(L10n.s("lang.\(code)")).tag(code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Picker("", selection: $state.config.language) {
                            Text(L10n.s("lang.auto")).tag("auto")
                            Text(L10n.s("lang.de")).tag("de")
                            Text(L10n.s("lang.en")).tag("en")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            SettingsSection(title: L10n.s("settings.recording.section"), icon: "waveform") {
                SettingRow(
                    title: L10n.s("settings.correction.title"),
                    detail: correctionDetail
                ) {
                    Toggle("", isOn: $state.config.autoCorrect)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!state.engineReady)
                }
                Divider()
                SettingRow(title: L10n.s("settings.sounds.title"), detail: L10n.s("settings.sounds.detail")) {
                    Toggle("", isOn: $state.config.playSounds).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingRow(title: L10n.s("settings.mute.title"), detail: L10n.s("settings.mute.detail")) {
                    Picker("", selection: $state.config.othersAudio) {
                        Text(L10n.s("audio.off")).tag(OthersAudio.off.rawValue)
                        Text(L10n.s("audio.quiet")).tag(OthersAudio.quiet.rawValue)
                        Text(L10n.s("audio.mute")).tag(OthersAudio.mute.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
            }

            SettingsSection(title: L10n.s("settings.advanced.section"), icon: "slider.horizontal.3") {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingRow(title: L10n.s("settings.widget.show.title"), detail: L10n.s("settings.widget.show.detail")) {
                            Toggle("", isOn: $state.config.showWidget).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(title: L10n.s("settings.widgetFollow.title"), detail: L10n.s("settings.widgetFollow.detail")) {
                            Toggle("", isOn: $state.config.widgetFollowActiveScreen).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(title: L10n.s("settings.resultSize.title"), detail: L10n.s("settings.resultSize.detail")) {
                            Picker("", selection: $state.config.overlayResultSize) {
                                ForEach(OverlayResultSize.allCases) { size in
                                    Text(L10n.s(size.titleKey)).tag(size.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: .infinity)
                        }
                        Divider()
                        SettingRow(title: L10n.s("settings.resultDismiss.title"), detail: L10n.s("settings.resultDismiss.detail")) {
                            Picker("", selection: $state.config.overlayResultDismissSeconds) {
                                ForEach(FlowConfig.overlayDismissChoices, id: \.self) { seconds in
                                    Text(dismissLabel(seconds)).tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider()
                        SettingRow(title: L10n.s("settings.dictationPreview.title"), detail: L10n.s("settings.dictationPreview.detail")) {
                            Toggle("", isOn: $state.config.showDictationPreview).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(
                            title: L10n.s("settings.dictationPreview.dismiss.title"),
                            detail: L10n.s("settings.dictationPreview.dismiss.detail")
                        ) {
                            Picker("", selection: $state.config.dictationPreviewDismissSeconds) {
                                ForEach(FlowConfig.dictationPreviewDismissChoices, id: \.self) { seconds in
                                    Text(dismissLabel(seconds)).tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider()
                        SettingRow(title: L10n.s("settings.resultPlace.title"), detail: L10n.s("settings.resultPlace.detail")) {
                            Toggle("", isOn: $state.config.resultPlacementFixed).labelsHidden().toggleStyle(.switch)
                        }
                        if state.config.resultPlacementFixed {
                            ResultPlacementSettings(
                                screenKey: $state.config.resultPlacementScreen,
                                anchor: $state.config.resultPlacementAnchor
                            )
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text(showAdvanced ? L10n.s("settings.advanced.hide") : L10n.s("settings.advanced.show"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: L10n.s("settings.system.section"), icon: "macwindow") {
                SettingRow(title: L10n.s("settings.login.title"), detail: L10n.s("settings.login.detail")) {
                    Toggle("", isOn: $state.config.launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsSection(title: L10n.s("settings.permissions.section"), icon: "lock.shield") {
                PermissionRow(
                    title: L10n.s("common.mic"),
                    detail: L10n.s("settings.mic.detail"),
                    icon: "mic.fill",
                    granted: state.micGranted,
                    action: state.requestMicrophone
                )
                Divider()
                PermissionRow(
                    title: L10n.s("common.accessibility"),
                    detail: L10n.s("settings.ax.detail"),
                    icon: "accessibility",
                    granted: state.axGranted,
                    action: state.openAccessibility,
                    repairHint: L10n.s("settings.ax.repair")
                )
                if !state.axGranted {
                    Divider()
                    AccessibilityRepairCard()
                }
            }

            SettingsSection(title: L10n.s("settings.asr.title"), icon: "waveform") {
                SettingRow(title: L10n.s("settings.asr.engine"), detail: L10n.s("settings.asr.engine.detail")) {
                    Picker("", selection: asrEngineBinding) {
                        Text(L10n.s("settings.asr.whisper")).tag("whisper")
                        Text(L10n.s("settings.asr.whistle")).tag("whistle")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
                Divider()
                SettingRow(title: L10n.s("settings.asr.quality"), detail: asrQualityDetail) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Slider(
                            value: asrQualitySlider,
                            in: 0...Double(FlowConfig.asrQualityMax),
                            step: 1
                        )
                        HStack {
                            Text(L10n.s("settings.asr.quality.low"))
                            Spacer()
                            Text(L10n.s("settings.asr.quality.high"))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                Divider()
                SettingRow(
                    title: state.config.usesWhistle
                        ? L10n.s("settings.asr.whistle")
                        : L10n.s("settings.asr.whisper"),
                    detail: SnapshotMode.isActive
                        ? (state.config.usesWhistle
                           ? L10n.s("settings.whistle.local")
                           : L10n.s("settings.whisper.local"))
                        : (state.config.usesWhistle
                           ? L10n.s("settings.whistle.detail", SupportPaths.models.path)
                           : L10n.s("settings.whisper.path", SupportPaths.models.path))
                ) {
                    Button(L10n.s("settings.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([SupportPaths.models])
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                Divider()
                SettingRow(title: L10n.s("settings.status"), detail: state.engineStatus) {
                    HStack(spacing: 8) {
                        StatusPill(state: state.engineState, text: statusLabel)
                        Button(L10n.s("settings.restart")) { state.reloadEngine() }.buttonStyle(SoftButtonStyle())
                    }
                }
            }

            SettingsSection(title: L10n.s("settings.correction.section"), icon: "sparkles") {
                SettingRow(title: L10n.s("settings.correction.mode.title"), detail: L10n.s("settings.correction.mode.detail")) {
                    Picker("", selection: $state.config.correctionFallback) {
                        Text(L10n.s("settings.correction.mode.single")).tag(false)
                        Text(L10n.s("settings.correction.mode.list")).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
                Divider()
                if state.config.correctionFallback {
                    Text(L10n.s("settings.correction.list.hint"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    List {
                        ForEach(state.config.correctionEndpoints) { item in
                            if let index = state.config.correctionEndpoints.firstIndex(where: { $0.id == item.id }) {
                                CorrectionEndpointEditor(
                                    endpoint: $state.config.correctionEndpoints[index],
                                    apiKey: keyBinding(for: state.config.correctionEndpoints[index]),
                                    models: models(for: state.config.correctionEndpoints[index]),
                                    recommendedTitle: recommendedTitle(for: state.config.correctionEndpoints[index]),
                                    onLookup: { lookup(state.config.correctionEndpoints[index]) },
                                    onSave: { saveKey(for: state.config.correctionEndpoints[index]) },
                                    lookupError: state.correctionLookupErrors[state.config.correctionEndpoints[index].resolvedBaseURL],
                                    onKindChanged: { reloadKey(for: state.config.correctionEndpoints[index]) },
                                    onRemove: { removeEndpoint(item.id) },
                                    canRemove: state.config.correctionEndpoints.count > 1
                                )
                                .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                        .onMove(perform: moveEndpoints)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: listHeight)
                    Button {
                        addEndpoint()
                    } label: {
                        Label(L10n.s("settings.correction.add"), systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SoftButtonStyle())
                } else if let index = state.config.correctionEndpoints.firstIndex(where: \.enabled)
                    ?? state.config.correctionEndpoints.indices.first {
                    CorrectionEndpointEditor(
                        endpoint: $state.config.correctionEndpoints[index],
                        apiKey: keyBinding(for: state.config.correctionEndpoints[index]),
                        models: models(for: state.config.correctionEndpoints[index]),
                        recommendedTitle: recommendedTitle(for: state.config.correctionEndpoints[index]),
                        onLookup: { lookup(state.config.correctionEndpoints[index]) },
                        onSave: { saveKey(for: state.config.correctionEndpoints[index]) },
                        lookupError: state.correctionLookupErrors[state.config.correctionEndpoints[index].resolvedBaseURL],
                        onKindChanged: { reloadKey(for: state.config.correctionEndpoints[index]) },
                        onRemove: {},
                        canRemove: false
                    )
                }
            }

            SettingsSection(title: L10n.s("update.settings.section"), icon: "arrow.down.app") {
                SettingRow(title: L10n.s("update.settings.title"), detail: updateDetail) {
                    HStack(spacing: 8) {
                        if state.update == .checking || state.isDownloadingUpdate {
                            ProgressView().controlSize(.small)
                        }
                        if state.availableRelease != nil {
                            Button(L10n.s("update.settings.install"), action: state.installAvailableUpdate)
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(state.isDownloadingUpdate)
                        }
                        Button(L10n.s("update.settings.check")) {
                            state.checkForUpdate(userInitiated: true)
                        }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(state.update == .checking || state.isDownloadingUpdate)
                    }
                }
                if state.update == .failed {
                    Divider()
                    SettingRow(title: L10n.s("update.settings.open"), detail: L10n.s("update.settings.failed")) {
                        Button(L10n.s("update.settings.open"), action: state.openUpdatePage)
                            .buttonStyle(SoftButtonStyle())
                    }
                }
            }

            SettingsSection(title: L10n.s("settings.data.section"), icon: "folder") {
                SettingRow(title: L10n.s("settings.history.keep.title"), detail: L10n.s("settings.history.keep.detail")) {
                    Picker("", selection: $state.config.historyKeepHours) {
                        ForEach(keepChoices, id: \.self) { hours in
                            Text(keepLabel(hours)).tag(hours)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                SettingRow(title: L10n.s("settings.history.limit.title"), detail: L10n.s("settings.history.limit.detail")) {
                    Picker("", selection: $state.config.historyMaxEntries) {
                        ForEach(limitChoices, id: \.self) { count in
                            Text(limitLabel(count)).tag(count)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                SettingRow(title: L10n.s("settings.storage.title"), detail: L10n.s("settings.storage.detail")) {
                    HStack(spacing: 8) {
                        Button(L10n.s("settings.reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([SupportPaths.config])
                        }
                        .buttonStyle(SoftButtonStyle())
                        Button(L10n.s("settings.log")) {
                            NSWorkspace.shared.open(SupportPaths.log)
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text(footerText)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .onAppear {
            loadKeys()
            if let first = state.config.activeCorrectionEndpoints.first {
                lookup(first)
            }
        }
        .onChange(of: keyDrafts) { _, _ in
            refreshPolishAvailable()
        }
        .onChange(of: state.config.correctionEndpoints) { _, _ in
            loadKeys()
            refreshPolishAvailable()
        }
        .onChange(of: state.config.correctionFallback) { _, _ in
            refreshPolishAvailable()
        }
    }

    private var updateDetail: String {
        switch state.update {
        case .checking:
            return L10n.s("update.settings.checking")
        case .current:
            return L10n.s("update.settings.currentOk")
        case .available(let release):
            return L10n.s("update.settings.available", release.version)
        case .downloading:
            return L10n.s("update.settings.downloading")
        case .failed:
            return L10n.s("update.settings.failed")
        case .idle:
            return L10n.s("update.settings.current", L10n.appVersion)
        }
    }

    private var footerText: String {
        if state.config.usesFallbackCorrection {
            return L10n.s("settings.footer.fallback", L10n.appVersion)
        }
        if state.config.usesCustomCorrectionAPI {
            return L10n.s("settings.footer.custom", L10n.appVersion)
        }
        if state.config.usesClaudeCorrection {
            return L10n.s("settings.footer.claude", L10n.appVersion)
        }
        if state.config.usesCursorCorrection {
            return L10n.s("settings.footer.cursor", L10n.appVersion)
        }
        return state.config.correctsWithOpenAI
            ? L10n.s("settings.footer.on", L10n.appVersion)
            : L10n.s("settings.footer.off", L10n.appVersion)
    }

    private var listHeight: CGFloat {
        CGFloat(max(1, state.config.correctionEndpoints.count)) * 176
    }

    private var keepChoices: [Int] {
        var hours = FlowConfig.historyKeepChoices
        let selected = state.config.historyKeepHours
        if !hours.contains(selected) {
            hours.append(selected)
            hours.sort()
        }
        return hours
    }

    private var limitChoices: [Int] {
        var counts = FlowConfig.historyLimitChoices
        let selected = state.config.historyMaxEntries
        if !counts.contains(selected) {
            counts.append(selected)
            counts.sort { a, b in
                if a == 0 { return false }
                if b == 0 { return true }
                return a < b
            }
        }
        return counts
    }

    private func keepLabel(_ hours: Int) -> String {
        switch hours {
        case 0: return L10n.s("settings.history.keep.forever")
        case 1: return L10n.s("settings.history.keep.hour")
        case 24: return L10n.s("settings.history.keep.day")
        case 48: return L10n.s("settings.history.keep.days", 2)
        case 168: return L10n.s("settings.history.keep.days", 7)
        case 720: return L10n.s("settings.history.keep.days", 30)
        case 2160: return L10n.s("settings.history.keep.days", 90)
        case 8760: return L10n.s("settings.history.keep.year")
        default:
            if hours % 24 == 0 {
                return L10n.s("settings.history.keep.days", hours / 24)
            }
            return L10n.s("settings.history.keep.hours", hours)
        }
    }

    private func limitLabel(_ count: Int) -> String {
        count == 0 ? L10n.s("settings.history.limit.unlimited") : L10n.s("settings.history.limit.count", count)
    }

    private func catalog(for endpoint: CorrectionEndpoint) -> CorrectionCatalog {
        state.correctionCatalogs[endpoint.resolvedBaseURL] ?? CorrectionCatalog()
    }

    private func recommendedTitle(for endpoint: CorrectionEndpoint) -> String {
        let recommended = catalog(for: endpoint).recommended
        return recommended.isEmpty
            ? L10n.s("settings.recommended")
            : L10n.s("settings.recommendedNamed", recommended)
    }

    private func models(for endpoint: CorrectionEndpoint) -> [String] {
        var ids = catalog(for: endpoint).models
        let selected = endpoint.model
        if selected != "auto", !selected.isEmpty, !ids.contains(selected) {
            ids.append(selected)
        }
        return ids
    }

    private func dismissLabel(_ seconds: Int) -> String {
        seconds == 0
            ? L10n.s("settings.resultDismiss.off")
            : L10n.s("settings.resultDismiss.seconds", seconds)
    }

    private var correctionDetail: String {
        if !state.config.autoCorrect {
            return L10n.s("settings.correction.off")
        }
        if state.config.usesFallbackCorrection {
            return L10n.s("settings.correction.fallback")
        }
        if state.config.usesCustomCorrectionAPI {
            return L10n.s("settings.correction.custom")
        }
        if state.config.usesClaudeCorrection {
            return L10n.s("settings.correction.onClaude")
        }
        if state.config.usesCursorCorrection {
            return L10n.s("settings.correction.onCursor")
        }
        let key = OpenAIKeyStore.load()
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.s("settings.correction.noKey")
        }
        return L10n.s("settings.correction.on")
    }

    private var recognitionDetail: String {
        state.config.usesWhistle
            ? L10n.s("settings.recognition.detail.whistle")
            : L10n.s("settings.recognition.detail")
    }

    private var asrQualityDetail: String {
        if state.config.usesWhistle {
            return L10n.s("settings.asr.quality.whistle", state.config.whistleDepth)
        }
        let id = state.config.resolvedWhisperModel
            .split(separator: "/")
            .last
            .map(String.init) ?? state.config.resolvedWhisperModel
        return L10n.s("settings.asr.quality.whisper", id)
    }

    private var asrEngineBinding: Binding<String> {
        Binding(
            get: { state.config.asrEngine },
            set: { next in
                guard next == "whisper" || next == "whistle" else { return }
                state.config.asrEngine = next
                if !state.config.usesWhistle {
                    state.config.whisperModel = FlowConfig.whisperModel(for: state.config.clampedAsrQuality)
                }
                if !state.config.recognitionLanguages.contains(state.config.language) {
                    state.config.language = "auto"
                }
            }
        )
    }

    private var asrQualitySlider: Binding<Double> {
        Binding(
            get: { Double(state.config.clampedAsrQuality) },
            set: { state.config.applyAsrQuality(Int($0.rounded())) }
        )
    }

    private var statusLabel: String {
        switch state.engineState {
        case .ready: return L10n.s("status.ready")
        case .loading: return L10n.s("status.loading")
        case .error: return L10n.s("status.error")
        }
    }

    private func keyBinding(for endpoint: CorrectionEndpoint) -> Binding<String> {
        let account = OpenAIKeyStore.account(for: endpoint)
        return Binding(
            get: { keyDrafts[account] ?? "" },
            set: { keyDrafts[account] = $0 }
        )
    }

    /// Schreibt den Feldinhalt in den Schlüsselbund und lädt danach die Modellliste.
    private func saveKey(for endpoint: CorrectionEndpoint) -> Bool {
        let account = OpenAIKeyStore.account(for: endpoint)
        let raw = (keyDrafts[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        keyDrafts[account] = raw
        guard OpenAIKeyStore.save(raw, for: endpoint) else { return false }
        let stored = OpenAIKeyStore.key(for: endpoint).trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored == raw else { return false }
        refreshPolishAvailable()
        lookup(endpoint)
        state.noteSettingChanged()
        return true
    }

    private func loadKeys() {
        var next = keyDrafts
        for endpoint in state.config.correctionEndpoints {
            let account = OpenAIKeyStore.account(for: endpoint)
            if next[account] == nil {
                next[account] = OpenAIKeyStore.key(for: endpoint)
            }
        }
        keyDrafts = next
    }

    /// After switching ChatGPT ↔ Claude ↔ Cursor, show that provider’s own key again.
    private func reloadKey(for endpoint: CorrectionEndpoint) {
        let account = OpenAIKeyStore.account(for: endpoint)
        keyDrafts[account] = OpenAIKeyStore.key(for: endpoint)
        lookup(endpoint)
    }

    private func lookup(_ endpoint: CorrectionEndpoint) {
        let account = OpenAIKeyStore.account(for: endpoint)
        let key = keyDrafts[account] ?? OpenAIKeyStore.key(for: endpoint)
        state.lookupCorrectionModel(key, endpoint.resolvedBaseURL)
    }

    private func refreshPolishAvailable() {
        let hasKey = !OpenAIKeyStore.load().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state.polishAvailable = state.engineReady && state.config.correctionConfigured(hasKey: hasKey)
    }

    private func moveEndpoints(from offsets: IndexSet, to destination: Int) {
        state.config.correctionEndpoints.move(fromOffsets: offsets, toOffset: destination)
    }

    private func addEndpoint() {
        state.config.correctionEndpoints.append(.custom())
    }

    private func removeEndpoint(_ id: UUID) {
        if let endpoint = state.config.correctionEndpoints.first(where: { $0.id == id }), endpoint.isCustom {
            let account = OpenAIKeyStore.account(for: endpoint)
            keyDrafts[account] = nil
            OpenAIKeyStore.save("", for: endpoint)
        }
        state.config.correctionEndpoints.removeAll { $0.id == id }
        if state.config.correctionEndpoints.isEmpty {
            state.config.correctionEndpoints = [.chatgpt()]
        }
    }

}

private struct CorrectionEndpointEditor: View {
    @Binding var endpoint: CorrectionEndpoint
    @Binding var apiKey: String
    let models: [String]
    let recommendedTitle: String
    let onLookup: () -> Void
    let onSave: () -> Bool
    var lookupError: String?
    let onKindChanged: () -> Void
    let onRemove: () -> Void
    var canRemove: Bool
    @State private var keyNote: String?
    @State private var keySaved = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .opacity(canRemove ? 1 : 0.35)
            fields
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(endpoint.enabled ? Theme.violet.opacity(0.35) : Theme.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .onChange(of: endpoint.kind) { _, _ in
            endpoint.model = "auto"
            keyNote = nil
            keySaved = false
            onKindChanged()
        }
        .onChange(of: apiKey) { _, _ in
            keyNote = nil
            keySaved = false
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $endpoint.kind) {
                    Text(L10n.s("settings.correction.chatgpt")).tag("chatgpt")
                    Text(L10n.s("settings.correction.claude")).tag("claude")
                    Text(L10n.s("settings.correction.cursor")).tag("cursor")
                    Text(L10n.s("settings.correction.own")).tag("custom")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $endpoint.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(L10n.s("settings.correction.enabled"))
                if canRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(L10n.s("settings.correction.remove"))
                }
            }
            if endpoint.usesModelCatalog {
                if models.isEmpty, lookupError?.isEmpty != false {
                    Text(catalogHint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("", selection: $endpoint.model) {
                        Text(recommendedTitle).tag("auto")
                        Divider()
                        ForEach(models, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                TextField(L10n.s("settings.api.placeholder"), text: $endpoint.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onLookup)
                    .onChange(of: endpoint.baseURL) { _, _ in onLookup() }
                TextField(L10n.s("settings.model.namePlaceholder"), text: modelName)
                    .textFieldStyle(.roundedBorder)
                    .help(L10n.s("settings.model.customHint"))
            }
            HStack(spacing: 6) {
                SecureField(keyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit(commitKey)
                Button(L10n.s("settings.key.save"), action: commitKey)
                    .buttonStyle(SoftButtonStyle())
                if let url = OpenAIKeyStore.keySetupURL(for: endpoint) {
                    Button(L10n.s("settings.correction.getKey")) {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
            if let note = keyStatusText {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(keySaved && lookupError == nil ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(endpoint.enabled ? 1 : 0.6)
    }

    private func commitKey() {
        let ok = onSave()
        keySaved = ok
        keyNote = ok ? L10n.s("settings.key.saved") : L10n.s("settings.key.saveFailed")
    }

    private var keyStatusText: String? {
        if let lookupError, !lookupError.isEmpty { return lookupError }
        return keyNote
    }

    private var catalogHint: String {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.s("settings.model.needsKey")
        }
        return L10n.s("settings.model.looking")
    }

    private var modelName: Binding<String> {
        Binding(
            get: { endpoint.model == "auto" ? "" : endpoint.model },
            set: { endpoint.model = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private var keyPlaceholder: String {
        switch endpoint.kind {
        case "claude": return "sk-ant-…"
        case "cursor": return "crsr_…"
        default: return "sk-…"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .card(padding: 18)
        }
    }
}

enum SettingsLayout {
    /// Shared trailing column so toggles, pickers and sliders share one right edge.
    static let controlWidth: CGFloat = 260
}

private struct ResultScreenChoice: Identifiable {
    let id: String
    let name: String
}

private struct ResultPlacementSettings: View {
    @Binding var screenKey: String
    @Binding var anchor: String
    @State private var screens: [ResultScreenChoice] = []

    var body: some View {
        Group {
            Divider()
            SettingRow(
                title: L10n.s("settings.resultPlace.screen"),
                detail: L10n.s("settings.resultPlace.screen.detail")
            ) {
                Picker("", selection: $screenKey) {
                    Text(L10n.s("settings.resultPlace.screen.pointer"))
                        .tag(FlowConfig.resultPlacementPointerScreen)
                    ForEach(screens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Divider()
            SettingRow(
                title: L10n.s("settings.resultPlace.anchor"),
                detail: L10n.s("settings.resultPlace.anchor.detail")
            ) {
                ResultPlacementMap(anchor: $anchor)
            }
        }
        .onAppear(perform: reloadScreens)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            reloadScreens()
        }
    }

    private func reloadScreens() {
        let ordered = NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.minY < rhs.frame.minY
        }
        let names = ordered.map(\.localizedName)
        screens = ordered.enumerated().compactMap { index, screen in
            guard let id = screen.displayID else { return nil }
            let base = screen.localizedName
            let label = names.filter { $0 == base }.count > 1 ? "\(base) \(index + 1)" : base
            return ResultScreenChoice(id: String(id), name: label)
        }
    }
}

private struct ResultPlacementMap: View {
    @Binding var anchor: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                spot(.topLeading)
                Spacer(minLength: 0)
                spot(.topCenter)
                Spacer(minLength: 0)
                spot(.topTrailing)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                spot(.bottomLeading)
                Spacer(minLength: 0)
                spot(.bottomCenter)
                Spacer(minLength: 0)
                spot(.bottomTrailing)
            }
        }
        .padding(10)
        .frame(width: 160, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func spot(_ place: ResultPlacementAnchor) -> some View {
        let selected = anchor == place.rawValue
        return Button {
            anchor = place.rawValue
        } label: {
            Circle()
                .fill(selected ? Theme.violet : Color.primary.opacity(0.28))
                .frame(width: selected ? 14 : 10, height: selected ? 14 : 10)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(L10n.s(place.titleKey))
        .accessibilityLabel(L10n.s(place.titleKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .frame(width: SettingsLayout.controlWidth, alignment: .trailing)
        }
    }
}
