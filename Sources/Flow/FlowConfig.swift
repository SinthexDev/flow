import Foundation

struct CorrectionEndpoint: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    /// chatgpt / claude / cursor / custom
    var kind: String
    var model: String
    var baseURL: String
    var enabled: Bool

    static let knownKinds = ["chatgpt", "claude", "cursor", "custom"]

    static func chatgpt(model: String = "auto") -> CorrectionEndpoint {
        CorrectionEndpoint(id: UUID(), kind: "chatgpt", model: model, baseURL: "", enabled: true)
    }

    static func claude(model: String = "auto") -> CorrectionEndpoint {
        CorrectionEndpoint(id: UUID(), kind: "claude", model: model, baseURL: "", enabled: true)
    }

    static func cursor(model: String = "auto") -> CorrectionEndpoint {
        CorrectionEndpoint(id: UUID(), kind: "cursor", model: model, baseURL: "", enabled: true)
    }

    static func custom(model: String = "auto", baseURL: String = "") -> CorrectionEndpoint {
        CorrectionEndpoint(id: UUID(), kind: "custom", model: model, baseURL: baseURL, enabled: true)
    }

    var isChatGPT: Bool { kind == "chatgpt" }
    var isClaude: Bool { kind == "claude" }
    var isCursor: Bool { kind == "cursor" }
    var isCustom: Bool { kind == "custom" }
    /// Modellliste kommt von der API (OpenAI, Anthropic, Cursor).
    var usesModelCatalog: Bool { !isCustom }
    var needsAPIKey: Bool { !isCustom }

    var resolvedBaseURL: String {
        switch kind {
        case "claude": return FlowConfig.claudeCorrectionBaseURL
        case "cursor": return FlowConfig.cursorCorrectionBaseURL
        case "custom": return baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return FlowConfig.defaultCorrectionBaseURL
        }
    }

    func isReady(hasKey: Bool) -> Bool {
        if needsAPIKey { return hasKey }
        return !resolvedBaseURL.isEmpty
    }
}

struct CorrectionCatalog: Equatable {
    var recommended: String = ""
    var models: [String] = []
}

struct OverlayResult: Equatable {
    var command: String
    var text: String
    /// Bei Unsicherheit: Nutzer wählt zwischen Befehl und Umformulierung.
    var choices: [OverlayResultChoice]? = nil

    var isChoice: Bool { !(choices ?? []).isEmpty }
}

struct OverlayResultChoice: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case command
        case reformulate
    }

    var id: String { kind.rawValue }
    var kind: Kind
    var title: String
    var text: String
}

struct FlowConfig: Codable, Equatable {
    var modelPath: String
    var whisperModel: String
    /// whisper = mlx-whisper, whistle = Cactus Whistle (kleiner, 7 Sprachen)
    var asrEngine: String
    /// 0 = schnell/klein … 4 = genau/groß (Whisper-Modell bzw. Whistle-Depth)
    var asrQuality: Int
    /// local = Qwen auf diesem Mac, openai = Chat-API mit eigenem Schlüssel
    var polishProvider: String
    var openAIModel: String
    /// Leer = https://api.openai.com/v1. Sonst eine OpenAI-kompatible Basisadresse.
    var correctionBaseURL: String = ""
    /// chatgpt = OpenAI. custom = eigene Adresse und eigenes Modell.
    var correctionKind: String = "chatgpt"
    /// false = nur das erste aktive Modell. true = Reihenfolge als Fallback.
    var correctionFallback: Bool = false
    /// "flow" oder Ordner der Notizen-App (Konto und Name, getrennt).
    var noteDestination: String = FlowConfig.noteDestinationAppleNotes
    var correctionEndpoints: [CorrectionEndpoint] = []
    /// true, sobald die alte Modell-Vorgabe einmal auf „auto“ umgestellt wurde
    var didChooseModel: Bool
    var appStyles: [AppStyleProfile]
    /// Erkennungssprache: auto / de / en (Whisper); plus fr/es/it/nl/pl bei Whistle
    var language: String
    /// Muttersprache für Übersetzungen (de, en, …)
    var nativeLanguage: String
    var style: String
    var instructions: String
    var dictionary: String
    var commandMode: Bool
    /// false = nur Whisper, keine Nachbearbeitung
    var autoCorrect: Bool
    var hotkey: String
    var playSounds: Bool
    /// Während der Aufnahme: off, quiet oder mute.
    var othersAudio: String
    /// Kurze Korrekturen am eingesetzten Text ins Wörterbuch übernehmen.
    var learnEdits: Bool
    var launchAtLogin: Bool
    var onboarded: Bool
    var port: Int
    /// Widget-Mitte relativ zum sichtbaren Bildschirm (0…1). nil = Standard unten mittig.
    var widgetX: Double?
    var widgetY: Double?
    /// CGDirectDisplayID des Bildschirms, auf dem das Widget zu Hause ist.
    var widgetDisplayID: Int? = nil
    /// true = während Aufnahme/Ergebnis dem Bildschirm unter dem Zeiger folgen.
    /// false = immer an der gespeicherten Stelle bleiben (kein Springen).
    var widgetFollowActiveScreen: Bool = true
    /// Floating-Widget auch im Leerlauf. Aus = Widget nur bei Aufnahme/Verarbeitung; Menüleiste bleibt.
    var showWidget: Bool = false
    /// Größe des Ergebnis-Fensters über dem Widget: compact / regular / large.
    var overlayResultSize: String = OverlayResultSize.large.rawValue
    /// Sekunden, bis das Befehlsfenster von allein schließt. 0 = bleibt offen.
    var overlayResultDismissSeconds: Int = 15
    /// 0 = unbegrenzt. Sonst werden ältere Einträge nach so vielen Stunden entfernt.
    var historyKeepHours: Int = 168
    /// 0 = unbegrenzt. Sonst bleiben nur so viele neueste Einträge.
    var historyMaxEntries: Int = 500
    /// Nach dem Diktat den erkannten Text kurz im Minifenster zeigen.
    var showDictationPreview: Bool = true
    /// Sekunden, bis die Diktat-Vorschau nach erfolgreichem Einfügen schließt. 0 = bleibt offen.
    var dictationPreviewDismissSeconds: Int = 1
    /// true = Ergebnis- und Diktat-Karten an einem festen Anker, nicht am Widget-Platz.
    var resultPlacementFixed: Bool = true
    /// `"pointer"` oder die Display-ID als String.
    var resultPlacementScreen: String = resultPlacementPointerScreen
    /// Rohwert von `ResultPlacementAnchor`.
    var resultPlacementAnchor: String = ResultPlacementAnchor.topCenter.rawValue

    static let resultPlacementPointerScreen = "pointer"

    /// Stunden: unbegrenzt, 1 h, 2 h, 6 h, 12 h, 1 T, 2 T, 7 T, 30 T, 90 T, 1 J.
    static let historyKeepChoices = [0, 1, 2, 6, 12, 24, 48, 168, 720, 2160, 8760]
    static let historyLimitChoices = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 0]
    static let overlayDismissChoices = [1, 2, 3, 5, 10, 15, 30, 60, 0]
    static let dictationPreviewDismissChoices = [1, 2, 3, 5, 10, 0]

    static let defaultModel = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Models/Qwen3.8-27B-Uncensored-MLX/4-bit")
    static let defaultWhisper = "mlx-community/whisper-large-v3-turbo"
    static let defaultAsrEngine = "whisper"
    static let defaultAsrQuality = 4
    static let asrQualityMax = 4
    static let defaultPolishProvider = "openai"
    static let defaultOpenAIModel = "gpt-4.1-mini"
    static let whistleLanguages = ["auto", "de", "en", "fr", "es", "it", "nl", "pl"]
    static let whisperLanguages = ["auto", "de", "en"]
    static let whisperModelsByQuality = [
        "mlx-community/whisper-tiny",
        "mlx-community/whisper-base-mlx",
        "mlx-community/whisper-small-mlx",
        "mlx-community/whisper-medium-mlx",
        "mlx-community/whisper-large-v3-turbo",
    ]
    static let whistleDepthsByQuality = [2, 3, 4, 6, 8]

    static let noteDestinationFlow = "flow"
    /// iCloud-Ordner „Notes“, der Standardordner der Notizen-App.
    static let noteDestinationAppleNotes = AppleNotesFolder.id(account: "iCloud", name: "Notes")
    /// Menüeintrag, der die Ordner der Notizen-App lädt und nicht gespeichert wird.
    static let noteDestinationPickApple = "__apple__"

    static let standard = FlowConfig(
        modelPath: defaultModel,
        whisperModel: defaultWhisper,
        asrEngine: defaultAsrEngine,
        asrQuality: defaultAsrQuality,
        polishProvider: defaultPolishProvider,
        openAIModel: "auto",
        didChooseModel: true,
        appStyles: [],
        language: "auto",
        nativeLanguage: "de",
        style: "auto",
        instructions: "",
        dictionary: "",
        commandMode: true,
        autoCorrect: true,
        hotkey: Hotkey.function.rawValue,
        playSounds: true,
        othersAudio: OthersAudio.mute.rawValue,
        learnEdits: true,
        launchAtLogin: true,
        onboarded: false,
        port: 17321,
        widgetX: nil,
        widgetY: nil
    )

    init(
        modelPath: String,
        whisperModel: String,
        asrEngine: String,
        asrQuality: Int,
        polishProvider: String,
        openAIModel: String,
        didChooseModel: Bool,
        appStyles: [AppStyleProfile],
        language: String,
        nativeLanguage: String,
        style: String,
        instructions: String,
        dictionary: String,
        commandMode: Bool,
        autoCorrect: Bool,
        hotkey: String,
        playSounds: Bool,
        othersAudio: String,
        learnEdits: Bool,
        launchAtLogin: Bool,
        onboarded: Bool,
        port: Int,
        widgetX: Double?,
        widgetY: Double?
    ) {
        self.modelPath = modelPath
        self.whisperModel = whisperModel
        self.asrEngine = asrEngine
        self.asrQuality = min(Self.asrQualityMax, max(0, asrQuality))
        self.polishProvider = polishProvider
        self.openAIModel = openAIModel
        self.didChooseModel = didChooseModel
        self.appStyles = appStyles
        self.language = language
        self.nativeLanguage = nativeLanguage
        self.style = style
        self.instructions = instructions
        self.dictionary = dictionary
        self.commandMode = commandMode
        self.autoCorrect = autoCorrect
        self.hotkey = hotkey
        self.playSounds = playSounds
        self.othersAudio = othersAudio
        self.learnEdits = learnEdits
        self.launchAtLogin = launchAtLogin
        self.onboarded = onboarded
        self.port = port
        self.widgetX = widgetX
        self.widgetY = widgetY
        self.correctionEndpoints = [.chatgpt(model: openAIModel)]
    }

    init(from decoder: Decoder) throws {
        let d = FlowConfig.standard
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? d.modelPath
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        if let engine = try c.decodeIfPresent(String.self, forKey: .asrEngine),
           engine == "whisper" || engine == "whistle" {
            asrEngine = engine
        } else {
            asrEngine = d.asrEngine
        }
        if let stored = try c.decodeIfPresent(Int.self, forKey: .asrQuality) {
            asrQuality = min(Self.asrQualityMax, max(0, stored))
        } else if let matched = Self.quality(forWhisperModel: whisperModel) {
            asrQuality = matched
        } else {
            asrQuality = d.asrQuality
        }
        polishProvider = try c.decodeIfPresent(String.self, forKey: .polishProvider) ?? d.polishProvider
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        correctionBaseURL = try c.decodeIfPresent(String.self, forKey: .correctionBaseURL) ?? ""
        if let kind = try c.decodeIfPresent(String.self, forKey: .correctionKind),
           CorrectionEndpoint.knownKinds.contains(kind) {
            correctionKind = kind
        } else {
            let host = URL(string: correctionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
            correctionKind = (host != nil && host != "api.openai.com") ? "custom" : "chatgpt"
        }
        didChooseModel = try c.decodeIfPresent(Bool.self, forKey: .didChooseModel) ?? false
        appStyles = try c.decodeIfPresent([AppStyleProfile].self, forKey: .appStyles) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        nativeLanguage = try c.decodeIfPresent(String.self, forKey: .nativeLanguage) ?? d.nativeLanguage
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? d.style
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? d.instructions
        dictionary = try c.decodeIfPresent(String.self, forKey: .dictionary) ?? d.dictionary
        commandMode = try c.decodeIfPresent(Bool.self, forKey: .commandMode) ?? d.commandMode
        autoCorrect = try c.decodeIfPresent(Bool.self, forKey: .autoCorrect) ?? d.autoCorrect
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        if let stored = try c.decodeIfPresent(String.self, forKey: .othersAudio),
           OthersAudio(rawValue: stored) != nil {
            othersAudio = stored
        } else {
            let muted = try c.decodeIfPresent(Bool.self, forKey: .muteOthers) ?? true
            othersAudio = (muted ? OthersAudio.mute : OthersAudio.off).rawValue
        }
        learnEdits = try c.decodeIfPresent(Bool.self, forKey: .learnEdits) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        widgetX = try c.decodeIfPresent(Double.self, forKey: .widgetX)
        widgetY = try c.decodeIfPresent(Double.self, forKey: .widgetY)
        widgetDisplayID = try c.decodeIfPresent(Int.self, forKey: .widgetDisplayID)
        widgetFollowActiveScreen = try c.decodeIfPresent(Bool.self, forKey: .widgetFollowActiveScreen) ?? true
        // Neu: aus = nur Menüleiste. Altes widgetAlwaysVisible wird nicht übernommen,
        // damit der neue Standard „aus“ für alle gilt, bis man es unter Erweitert einschaltet.
        showWidget = try c.decodeIfPresent(Bool.self, forKey: .showWidget) ?? false
        if let size = try c.decodeIfPresent(String.self, forKey: .overlayResultSize),
           OverlayResultSize(rawValue: size) != nil {
            overlayResultSize = size
        } else {
            overlayResultSize = OverlayResultSize.large.rawValue
        }
        if let hours = try c.decodeIfPresent(Int.self, forKey: .historyKeepHours) {
            historyKeepHours = max(0, hours)
        } else if let days = try c.decodeIfPresent(Int.self, forKey: .historyKeepDays) {
            historyKeepHours = max(0, days) * 24
        } else {
            historyKeepHours = 168
        }
        historyMaxEntries = max(0, try c.decodeIfPresent(Int.self, forKey: .historyMaxEntries) ?? 500)
        showDictationPreview = try c.decodeIfPresent(Bool.self, forKey: .showDictationPreview) ?? true
        if let stored = try c.decodeIfPresent(Int.self, forKey: .overlayResultDismissSeconds) {
            overlayResultDismissSeconds = max(0, stored)
        } else {
            overlayResultDismissSeconds = 15
        }
        if let stored = try c.decodeIfPresent(Int.self, forKey: .dictationPreviewDismissSeconds) {
            dictationPreviewDismissSeconds = max(0, stored)
        } else {
            dictationPreviewDismissSeconds = 1
        }
        resultPlacementFixed = try c.decodeIfPresent(Bool.self, forKey: .resultPlacementFixed) ?? true
        if let stored = try c.decodeIfPresent(String.self, forKey: .resultPlacementScreen), !stored.isEmpty {
            resultPlacementScreen = stored
        } else {
            resultPlacementScreen = Self.resultPlacementPointerScreen
        }
        if let stored = try c.decodeIfPresent(String.self, forKey: .resultPlacementAnchor),
           ResultPlacementAnchor(rawValue: stored) != nil {
            resultPlacementAnchor = stored
        } else {
            resultPlacementAnchor = ResultPlacementAnchor.topCenter.rawValue
        }
        if let stored = try c.decodeIfPresent([CorrectionEndpoint].self, forKey: .correctionEndpoints), !stored.isEmpty {
            correctionEndpoints = stored
        } else {
            correctionEndpoints = [
                CorrectionEndpoint(
                    id: UUID(),
                    kind: correctionKind,
                    model: openAIModel,
                    baseURL: correctionBaseURL,
                    enabled: true
                )
            ]
        }
        correctionFallback = try c.decodeIfPresent(Bool.self, forKey: .correctionFallback) ?? false
        if let stored = try c.decodeIfPresent(String.self, forKey: .noteDestination),
           stored == Self.noteDestinationFlow || AppleNotesFolder.decode(stored) != nil {
            noteDestination = stored
        } else {
            noteDestination = Self.noteDestinationAppleNotes
        }
        syncLegacyCorrectionFields()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var snapshot = self
        snapshot.syncLegacyCorrectionFields()
        try c.encode(snapshot.modelPath, forKey: .modelPath)
        try c.encode(snapshot.whisperModel, forKey: .whisperModel)
        try c.encode(snapshot.asrEngine, forKey: .asrEngine)
        try c.encode(snapshot.asrQuality, forKey: .asrQuality)
        try c.encode(snapshot.polishProvider, forKey: .polishProvider)
        try c.encode(snapshot.openAIModel, forKey: .openAIModel)
        try c.encode(snapshot.correctionBaseURL, forKey: .correctionBaseURL)
        try c.encode(snapshot.correctionKind, forKey: .correctionKind)
        try c.encode(snapshot.correctionFallback, forKey: .correctionFallback)
        try c.encode(snapshot.correctionEndpoints, forKey: .correctionEndpoints)
        try c.encode(didChooseModel, forKey: .didChooseModel)
        try c.encode(appStyles, forKey: .appStyles)
        try c.encode(language, forKey: .language)
        try c.encode(nativeLanguage, forKey: .nativeLanguage)
        try c.encode(style, forKey: .style)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(dictionary, forKey: .dictionary)
        try c.encode(commandMode, forKey: .commandMode)
        try c.encode(autoCorrect, forKey: .autoCorrect)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(playSounds, forKey: .playSounds)
        try c.encode(othersAudio, forKey: .othersAudio)
        try c.encode(othersAudio != OthersAudio.off.rawValue, forKey: .muteOthers)
        try c.encode(learnEdits, forKey: .learnEdits)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(onboarded, forKey: .onboarded)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(widgetX, forKey: .widgetX)
        try c.encodeIfPresent(widgetY, forKey: .widgetY)
        try c.encodeIfPresent(widgetDisplayID, forKey: .widgetDisplayID)
        try c.encode(widgetFollowActiveScreen, forKey: .widgetFollowActiveScreen)
        try c.encode(showWidget, forKey: .showWidget)
        try c.encode(overlayResultSize, forKey: .overlayResultSize)
        try c.encode(overlayResultDismissSeconds, forKey: .overlayResultDismissSeconds)
        try c.encode(historyKeepHours, forKey: .historyKeepHours)
        try c.encode(historyMaxEntries, forKey: .historyMaxEntries)
        try c.encode(showDictationPreview, forKey: .showDictationPreview)
        try c.encode(dictationPreviewDismissSeconds, forKey: .dictationPreviewDismissSeconds)
        try c.encode(resultPlacementFixed, forKey: .resultPlacementFixed)
        try c.encode(resultPlacementScreen, forKey: .resultPlacementScreen)
        try c.encode(resultPlacementAnchor, forKey: .resultPlacementAnchor)
        try c.encode(noteDestination, forKey: .noteDestination)
    }

    private enum CodingKeys: String, CodingKey {
        case modelPath, whisperModel, asrEngine, asrQuality, polishProvider, openAIModel, correctionBaseURL, correctionKind, correctionFallback, correctionEndpoints, didChooseModel, appStyles, language, nativeLanguage, style, instructions, dictionary
        case commandMode, autoCorrect, hotkey, playSounds, muteOthers, othersAudio, learnEdits, launchAtLogin, onboarded, port, widgetX, widgetY, widgetDisplayID, widgetFollowActiveScreen, showWidget, widgetAlwaysVisible, overlayResultSize, overlayResultDismissSeconds, historyKeepHours, historyKeepDays, historyMaxEntries, showDictationPreview, dictationPreviewDismissSeconds, resultPlacementFixed, resultPlacementScreen, resultPlacementAnchor, noteDestination
    }

    var usesWhistle: Bool { asrEngine == "whistle" }

    var recognitionLanguages: [String] {
        usesWhistle ? Self.whistleLanguages : Self.whisperLanguages
    }

    var clampedAsrQuality: Int {
        min(Self.asrQualityMax, max(0, asrQuality))
    }

    var whistleDepth: Int {
        Self.whistleDepthsByQuality[clampedAsrQuality]
    }

    var resolvedWhisperModel: String {
        Self.whisperModel(for: clampedAsrQuality)
    }

    static func whisperModel(for quality: Int) -> String {
        let index = min(asrQualityMax, max(0, quality))
        return whisperModelsByQuality[index]
    }

    static func whistleDepth(for quality: Int) -> Int {
        let index = min(asrQualityMax, max(0, quality))
        return whistleDepthsByQuality[index]
    }

    static func quality(forWhisperModel model: String) -> Int? {
        whisperModelsByQuality.firstIndex(of: model)
    }

    mutating func applyAsrQuality(_ quality: Int) {
        asrQuality = min(Self.asrQualityMax, max(0, quality))
        if !usesWhistle {
            whisperModel = Self.whisperModel(for: asrQuality)
        }
    }

    static var snapshotDemo: FlowConfig {
        var config = standard
        config.modelPath = ""
        config.polishProvider = defaultPolishProvider
        config.openAIModel = "auto"
        config.didChooseModel = true
        config.onboarded = true
        config.dictionary = "sintex flow -> Sinthex Flow\nbeexperts -> beeXperts"
        config.correctionFallback = true
        config.correctionEndpoints = [
            CorrectionEndpoint.chatgpt(model: "auto"),
            CorrectionEndpoint.custom(model: "llama3.2", baseURL: "http://127.0.0.1:11434/v1"),
        ]
        config.appStyles = [
            AppStyleProfile(bundleID: "com.apple.mail", name: "Mail", style: "email", suggested: "email", customized: false),
            AppStyleProfile(bundleID: "com.apple.MobileSMS", name: "Nachrichten", style: "chat", suggested: "chat", customized: false),
            AppStyleProfile(bundleID: "com.apple.Notes", name: "Notizen", style: "notes", suggested: "notes", customized: false),
            AppStyleProfile(bundleID: "com.apple.Terminal", name: "Terminal", style: "code", suggested: "code", customized: false),
            AppStyleProfile(bundleID: "com.microsoft.Word", name: "Word", style: "notes", suggested: "notes", customized: false),
            AppStyleProfile(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", style: "chat", suggested: "chat", customized: false),
        ]
        return config
    }

    static func load() -> FlowConfig {
        if SnapshotMode.isActive { return .snapshotDemo }
        guard let data = try? Data(contentsOf: SupportPaths.config) else { return .standard }
        var config = (try? JSONDecoder().decode(FlowConfig.self, from: data)) ?? .standard
        // „Lokal“ war das optionale Qwen-Modell. Fehlt es, bleibt die Korrektur bei OpenAI
        // und Whisper startet trotzdem.
        if !config.didChooseModel {
            if config.openAIModel.isEmpty || config.openAIModel == defaultOpenAIModel {
                config.openAIModel = "auto"
            }
            config.didChooseModel = true
            config.save()
        }
        if config.polishProvider == "local" {
            let present = FileManager.default.fileExists(
                atPath: (config.modelPath as NSString).appendingPathComponent("config.json")
            )
            if !present {
                config.polishProvider = defaultPolishProvider
                config.save()
            }
        }
        config.syncLegacyCorrectionFields()
        let parsed = DictionaryItem.parse(config.dictionary)
        let kept = parsed.filter(\.isKept)
        if kept.count != parsed.count {
            config.dictionary = DictionaryItem.serialize(kept)
            config.save()
        }
        return config
    }

    func save() {
        if SnapshotMode.isActive { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: SupportPaths.config, options: .atomic)
    }

    var resolvedHotkey: Hotkey {
        Hotkey(rawValue: hotkey) ?? .function
    }

    var resolvedOverlayResultSize: OverlayResultSize {
        OverlayResultSize(rawValue: overlayResultSize) ?? .regular
    }

    var resolvedOverlayDismissSeconds: Int {
        max(0, overlayResultDismissSeconds)
    }

    var resolvedDictationPreviewDismissSeconds: Int {
        max(0, dictationPreviewDismissSeconds)
    }

    var resolvedResultPlacementAnchor: ResultPlacementAnchor {
        ResultPlacementAnchor(rawValue: resultPlacementAnchor) ?? .bottomCenter
    }

    var othersAudioMode: OthersAudio {
        OthersAudio(rawValue: othersAudio) ?? .mute
    }

    var correctsWithOpenAI: Bool { polishProvider == "openai" }

    static let defaultCorrectionBaseURL = "https://api.openai.com/v1"
    static let claudeCorrectionBaseURL = "https://api.anthropic.com/v1"
    static let cursorCorrectionBaseURL = "https://api.cursor.com/v1"

    mutating func syncLegacyCorrectionFields() {
        if correctionEndpoints.isEmpty {
            correctionEndpoints = [.chatgpt(model: openAIModel.isEmpty ? "auto" : openAIModel)]
        }
        guard let first = correctionEndpoints.first else { return }
        correctionKind = first.kind
        openAIModel = first.model
        correctionBaseURL = first.baseURL
    }

    var enabledCorrectionEndpoints: [CorrectionEndpoint] {
        correctionEndpoints.filter(\.enabled)
    }

    /// Modelle, die jetzt an der Reihe sind: eines, oder die ganze Liste als Fallback.
    var activeCorrectionEndpoints: [CorrectionEndpoint] {
        let enabled = enabledCorrectionEndpoints
        if correctionFallback { return enabled }
        return Array(enabled.prefix(1))
    }

    var resolvedCorrectionBaseURL: String {
        activeCorrectionEndpoints.first?.resolvedBaseURL
            ?? (correctionKind != "custom" ? Self.defaultCorrectionBaseURL : correctionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Eigenes Modell über eine OpenAI-kompatible Adresse. Der Schlüssel ist dann optional.
    var usesCustomCorrectionAPI: Bool {
        let active = activeCorrectionEndpoints
        return !active.isEmpty && active.allSatisfy(\.isCustom)
    }

    var usesClaudeCorrection: Bool {
        let active = activeCorrectionEndpoints
        return active.count == 1 && active[0].isClaude
    }

    var usesCursorCorrection: Bool {
        let active = activeCorrectionEndpoints
        return active.count == 1 && active[0].isCursor
    }

    var usesFallbackCorrection: Bool {
        correctionFallback && enabledCorrectionEndpoints.count > 1
    }

    func correctionConfigured(hasKey: Bool) -> Bool {
        guard correctsWithOpenAI else { return false }
        return activeCorrectionEndpoints.contains { endpoint in
            if endpoint.isChatGPT { return endpoint.isReady(hasKey: hasKey) }
            let key = OpenAIKeyStore.key(for: endpoint)
            return endpoint.isReady(hasKey: !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func trimmedHistory(_ entries: [HistoryEntry], now: Date = Date()) -> [HistoryEntry] {
        var items = entries
        if historyKeepHours > 0 {
            let cutoff = Calendar.current.date(byAdding: .hour, value: -historyKeepHours, to: now) ?? now
            items = items.filter { $0.date >= cutoff }
        }
        if historyMaxEntries > 0, items.count > historyMaxEntries {
            items = Array(items.prefix(historyMaxEntries))
        }
        return items
    }
}

enum SupportPaths {
    static let folderName = "Sinthex Flow"
    static let legacyFolderName = "Flow"

    /// Builds before the rename kept everything in `Flow`. The first launch moves it over,
    /// and the engine is set up again because the virtual environment moved with it.
    static let directory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        if SnapshotMode.isActive { return url }
        let visible = (try? fm.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") } ?? []
        if visible.isEmpty, fm.fileExists(atPath: legacy.path) {
            try? fm.removeItem(at: url)
            if (try? fm.moveItem(at: legacy, to: url)) != nil {
                try? fm.removeItem(at: url.appendingPathComponent("engine.version"))
            }
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var config: URL { directory.appendingPathComponent("config.json") }
    static var history: URL { directory.appendingPathComponent("history.json") }
    static var notes: URL { directory.appendingPathComponent("notes.json") }
    static var models: URL {
        let url = directory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var log: URL { directory.appendingPathComponent("engine.log") }
    static var python: URL { directory.appendingPathComponent(".venv/bin/python") }
    static var timingLog: URL { directory.appendingPathComponent("timing.log") }
    static var engineVersion: URL { directory.appendingPathComponent("engine.version") }
}

/// Millisecond timeline of the dictation → paste path, appended to timing.log.
enum Timing {
    private static var start = Date()
    private static let queue = DispatchQueue(label: "flow.timing")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func begin(_ label: String) {
        start = Date()
        mark(label)
    }

    static func mark(_ label: String) {
        let now = Date()
        let line = "\(formatter.string(from: now))  +\(Int(now.timeIntervalSince(start) * 1000))ms  \(label)\n"
        queue.async {
            let url = SupportPaths.timingLog
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var raw: String
    var text: String
    var duration: Double?
    var app: String?
    var wasCommand: Bool?
    /// `"clipboard"` keeps text that was on the clipboard before an insert failed.
    var kind: String? = nil

    var keepsClipboard: Bool { kind == "clipboard" }

    var words: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

enum HistoryStore {
    static func load() -> [HistoryEntry] {
        if SnapshotMode.isActive { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: SupportPaths.history),
              let entries = try? decoder.decode([HistoryEntry].self, from: data) else { return [] }
        return entries
    }

    static func save(_ entries: [HistoryEntry]) {
        if SnapshotMode.isActive { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: SupportPaths.history, options: .atomic)
    }
}

struct DictionaryItem: Identifiable, Equatable {
    let id = UUID()
    var term: String
    var heardAs: String

    static func parse(_ text: String) -> [DictionaryItem] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if let range = line.range(of: "->") {
                let left = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else { return nil }
                return DictionaryItem(term: right, heardAs: left)
            }
            return DictionaryItem(term: line, heardAs: "")
        }
    }

    static func serialize(_ items: [DictionaryItem]) -> String {
        items.map { item in
            item.heardAs.isEmpty ? item.term : "\(item.heardAs) -> \(item.term)"
        }.joined(separator: "\n")
    }

    /// Gleiche Grenze wie in der Engine: keine reinen Großschreibungen, keine kurzen Funktionswörter.
    private static let ignoredWords: Set<String> = [
        "das", "der", "die", "den", "dem", "des", "ein", "eine", "einer", "einem",
        "einen", "eines", "mein", "meine", "meinem", "meinen", "meiner",
        "dein", "deine", "sein", "seine", "ihr", "ihre", "und", "oder", "aber",
        "nicht", "auch", "noch", "nur", "schon", "dann", "wenn", "dass", "ist",
        "sind", "war", "hat", "haben", "wird", "werden", "ich", "du", "er", "sie",
        "es", "wir", "man", "mit", "von", "zu", "auf", "für", "fur", "im", "in",
        "an", "am", "als", "wie", "doch", "mal", "the", "and", "for", "you", "your",
        "this", "that", "with", "was", "are"
    ]

    var isKept: Bool {
        heardAs.isEmpty
            ? Self.isUsefulHint(term)
            : Self.isUsefulRule(heard: heardAs, term: term)
    }

    static func isUsefulHint(_ term: String) -> Bool {
        guard quotesOk(term) else { return false }
        let folded = letters(term)
        return folded.count >= 3 && !ignoredWords.contains(folded)
    }

    static func isUsefulRule(heard: String, term: String) -> Bool {
        guard quotesOk(heard), quotesOk(term) else { return false }
        let left = letters(heard)
        let right = letters(term)
        guard left.count >= 3, right.count >= 3, left != right else { return false }
        return !ignoredWords.contains(left) && !ignoredWords.contains(right)
    }

    private static func letters(_ text: String) -> String {
        String(text.lowercased().filter(\.isLetter))
    }

    private static func quotesOk(_ text: String) -> Bool {
        if text.filter({ $0 == "\"" }).count % 2 != 0 { return false }
        if text.filter({ $0 == "„" }).count != text.filter({ $0 == "“" }).count { return false }
        return text.filter({ $0 == "«" }).count == text.filter({ $0 == "»" }).count
    }
}

struct TranslateLanguage: Identifiable, Hashable {
    let id: String
    let flag: String
    var name: String { L10n.s("lang.\(id)") }

    static let all: [TranslateLanguage] = [
        .init(id: "de", flag: "🇩🇪"),
        .init(id: "en", flag: "🇬🇧"),
        .init(id: "fr", flag: "🇫🇷"),
        .init(id: "es", flag: "🇪🇸"),
        .init(id: "it", flag: "🇮🇹"),
        .init(id: "pt", flag: "🇵🇹"),
        .init(id: "nl", flag: "🇳🇱"),
        .init(id: "pl", flag: "🇵🇱"),
        .init(id: "tr", flag: "🇹🇷")
    ]

    static func named(_ id: String) -> TranslateLanguage {
        all.first { $0.id == id } ?? all[0]
    }
}
