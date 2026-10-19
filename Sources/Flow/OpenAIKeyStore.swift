import Foundation
import Security

/// API keys in the Keychain. They never go into config.json.
///
/// Prefer the data-protection keychain so a local resign does not prompt for
/// the login password. This ad-hoc signature has no keychain entitlement, so
/// that write fails and the login keychain keeps the key instead.
///
/// Built-in providers (ChatGPT / Claude / Cursor) each have a stable account,
/// so switching the kind on one endpoint does not overwrite another key.
enum OpenAIKeyStore {
    private static let service = "de.sinthex.flow"
    /// Früherer Schlüsselbund-Name. Wird einmal gelesen und danach gelöscht.
    private static let legacyService = "de.dietergeschaeft.Flow"
    private static let openaiAccount = "openai-api-key"
    private static let claudeAccount = "claude-api-key"
    private static let cursorAccount = "cursor-api-key"
    private static let label = "Sinthex Flow OpenAI"
    private static let migratedDefaultsKey = "flow.keychain.dp.v2"
    private static var touchedAccounts = Set<String>()

    /// Keychain account for this endpoint’s provider (or a custom UUID slot).
    static func account(for endpoint: CorrectionEndpoint) -> String {
        switch endpoint.kind {
        case "chatgpt": return openaiAccount
        case "claude": return claudeAccount
        case "cursor": return cursorAccount
        default: return "correction.\(endpoint.id.uuidString)"
        }
    }

    /// Console / settings URL where the user can create an API key.
    static func keySetupURL(for endpoint: CorrectionEndpoint) -> URL? {
        switch endpoint.kind {
        case "chatgpt": return URL(string: "https://platform.openai.com/api-keys")
        case "claude": return URL(string: "https://console.anthropic.com/settings/keys")
        case "cursor": return URL(string: "https://cursor.com/settings")
        default: return nil
        }
    }

    static func load(_ id: UUID? = nil) -> String {
        if SnapshotMode.isActive { return "" }
        let account = id.map { "correction.\($0.uuidString)" } ?? openaiAccount
        return loadAccount(account, migrateLegacyOpenAI: id == nil)
    }

    @discardableResult
    static func save(_ raw: String, id: UUID? = nil) -> Bool {
        if SnapshotMode.isActive { return false }
        let account = id.map { "correction.\($0.uuidString)" } ?? openaiAccount
        return save(raw, account: account)
    }

    static func key(for endpoint: CorrectionEndpoint) -> String {
        let account = account(for: endpoint)
        let value = loadAccount(account, migrateLegacyOpenAI: endpoint.isChatGPT)
        if !value.isEmpty { return value }
        // Older builds stored Claude/Cursor keys under the endpoint UUID.
        guard !endpoint.isCustom else { return "" }
        let legacyAccount = "correction.\(endpoint.id.uuidString)"
        let legacy = loadAccount(legacyAccount, migrateLegacyOpenAI: false)
        guard !legacy.isEmpty else { return "" }
        save(legacy, account: account)
        return legacy
    }

    @discardableResult
    static func save(_ raw: String, for endpoint: CorrectionEndpoint) -> Bool {
        save(raw, account: account(for: endpoint))
    }

    private static func loadAccount(_ account: String, migrateLegacyOpenAI: Bool) -> String {
        if SnapshotMode.isActive { return "" }
        if let value = readDataProtection(service: service, account: account) {
            dropLoginCopy(account: account)
            return value
        }
        if let value = readLogin(service: service, account: account) {
            migrateToDataProtection(value, account: account)
            return value
        }
        guard migrateLegacyOpenAI, account == openaiAccount else { return "" }
        guard let legacy = readDataProtection(service: legacyService, account: openaiAccount)
                ?? readLogin(service: legacyService, account: openaiAccount) else {
            return ""
        }
        migrateToDataProtection(legacy, account: openaiAccount)
        delete(service: legacyService, account: openaiAccount)
        return legacy
    }

    @discardableResult
    private static func save(_ raw: String, account: String) -> Bool {
        if SnapshotMode.isActive { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = peek(account: account, migrateLegacyOpenAI: account == openaiAccount)
        if value == current {
            if !value.isEmpty { migrateToDataProtection(value, account: account) }
            return true
        }
        guard !value.isEmpty else {
            delete(service: service, account: account)
            markMigrated(account: account)
            return peek(account: account, migrateLegacyOpenAI: false).isEmpty
        }
        // Der data-protection-Schlüsselbund braucht eine Entitlement, die diese
        // lokal signierte App nicht hat (errSecMissingEntitlement). Erst schreiben,
        // den alten Eintrag nur ersetzen, wenn das geklappt hat.
        guard store(value, account: account) else { return false }
        markMigrated(account: account)
        return peek(account: account, migrateLegacyOpenAI: false) == value
    }

    /// Data-protection zuerst, sonst der normale Login-Schlüsselbund.
    @discardableResult
    private static func store(_ value: String, account: String) -> Bool {
        if upsert(value, account: account, dataProtection: true) { return true }
        return upsert(value, account: account, dataProtection: false)
    }

    private static func peek(account: String, migrateLegacyOpenAI: Bool) -> String {
        if let value = readDataProtection(service: service, account: account) { return value }
        if let value = readLogin(service: service, account: account) { return value }
        guard migrateLegacyOpenAI else { return "" }
        return readDataProtection(service: legacyService, account: openaiAccount)
            ?? readLogin(service: legacyService, account: openaiAccount)
            ?? ""
    }

    private static func migrateToDataProtection(_ value: String, account: String) {
        guard !touchedAccounts.contains(account) else { return }
        touchedAccounts.insert(account)
        // Login-Kopie nur löschen, wenn der data-protection-Eintrag wirklich steht.
        guard upsert(value, account: account, dataProtection: true) else { return }
        deleteLogin(service: service, account: account)
        markMigrated(account: account)
    }

    /// DP item is already correct; remove any leftover signature-bound login copy.
    private static func dropLoginCopy(account: String) {
        guard !touchedAccounts.contains(account) else { return }
        touchedAccounts.insert(account)
        deleteLogin(service: service, account: account)
        markMigrated(account: account)
    }

    private static func markMigrated(account: String) {
        guard account == openaiAccount else { return }
        UserDefaults.standard.set(true, forKey: migratedDefaultsKey)
    }

    private static func readLogin(service: String, account: String) -> String? {
        read(service: service, account: account, dataProtection: false)
    }

    private static func readDataProtection(service: String, account: String) -> String? {
        read(service: service, account: account, dataProtection: true)
    }

    private static func read(service: String, account: String, dataProtection: Bool) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8) ?? ""
        return value.isEmpty ? nil : value
    }

    @discardableResult
    private static func upsert(_ value: String, account: String, dataProtection: Bool) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
        let payload: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: label,
        ]
        let updated = SecItemUpdate(query as CFDictionary, payload as CFDictionary)
        if updated == errSecSuccess { return true }
        var add = query
        add[kSecAttrLabel as String] = label
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteLogin(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func delete(service: String, account: String) {
        for useDataProtection in [false, true] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: useDataProtection,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
