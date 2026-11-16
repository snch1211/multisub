//
//  SecretStore.swift
//  MultiSub
//
//  The user's own API keys (BYOK), one per cloud provider, in the keychain
//  access group the app and the Safari extension share. Keys never leave
//  native code: nothing here logs them, and native replies only ever say
//  whether a key exists.
//

import Foundation
import Security
import os

enum SecretStoreError: LocalizedError {
    case keychain(OSStatus)
    case file(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "無法儲存 API Key（鑰匙圈錯誤 \(status)）。"
        case .file: return "無法儲存 API Key。"
        }
    }
}

enum SecretStore {
    static let service = "MultiSub API Key"

    private static let log = Logger(subsystem: AppIdentity.appBundleID, category: "secrets")

    static func apiKey(for provider: CloudProvider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        case errSecMissingEntitlement where FileFallback.isAllowed:
            warnFallback()
            return FileFallback.read()[provider.rawValue]
        default:
            return nil
        }
    }

    static func setAPIKey(_ key: String, for provider: CloudProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            deleteAPIKey(for: provider)
            return
        }
        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery(provider) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(provider)
            add.merge(attributes) { _, new in new }
            add[kSecAttrLabel as String] = "MultiSub – \(provider.displayName)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        switch status {
        case errSecSuccess:
            return
        case errSecMissingEntitlement where FileFallback.isAllowed:
            warnFallback()
            try FileFallback.write { $0[provider.rawValue] = key }
        default:
            log.error("keychain write failed: \(status, privacy: .public)")
            throw SecretStoreError.keychain(status)
        }
    }

    /// Removes the key from the keychain and from the file fallback, so a
    /// delete always sticks whichever store the key ended up in.
    static func deleteAPIKey(for provider: CloudProvider) {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound, status != errSecMissingEntitlement {
            log.error("keychain delete failed: \(status, privacy: .public)")
        }
        if FileFallback.isAllowed { try? FileFallback.write { $0[provider.rawValue] = nil } }
    }

    /// Asks without reading the secret itself.
    static func hasAPIKey(for provider: CloudProvider) -> Bool {
        var query = baseQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return true
        case errSecMissingEntitlement where FileFallback.isAllowed:
            return !(FileFallback.read()[provider.rawValue] ?? "").isEmpty
        default: return false
        }
    }

    // MARK: - Keychain

    /// Data-protection keychain (no legacy file-keychain prompts) in the
    /// shared access group, so the extension reads what the app saved and
    /// vice versa.
    private static func baseQuery(_ provider: CloudProvider) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = AppIdentity.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private static func warnFallback() {
        log.warning("keychain unavailable (missing entitlement); using secrets.json in the shared container")
    }

    // MARK: - File fallback

    /// Only for builds signed without the keychain entitlement (unusual dev
    /// signing): a 0600 JSON file in the App Group container, which only
    /// processes signed by the same team can open.
    private enum FileFallback {
        /// The Mac App Store build is always signed with the keychain group,
        /// so it never falls back to a file; a missing entitlement there is
        /// a signing bug that should surface as an error, not a plaintext key.
        #if APP_STORE
        static let isAllowed = false
        #else
        static let isAllowed = true
        #endif

        private static let lock = NSLock()
        private static var url: URL { MultiSubPaths.sharedRoot.appendingPathComponent("secrets.json") }

        static func read() -> [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return load()
        }

        static func write(_ change: (inout [String: String]) -> Void) throws {
            lock.lock()
            defer { lock.unlock() }
            var secrets = load()
            let before = secrets
            change(&secrets)
            guard secrets != before else { return }
            let fm = FileManager.default
            if secrets.isEmpty {
                try? fm.removeItem(at: url)
                return
            }
            do {
                let data = try JSONEncoder().encode(secrets)
                try data.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                throw SecretStoreError.file(error.localizedDescription)
            }
        }

        private static func load() -> [String: String] {
            guard let data = try? Data(contentsOf: url),
                  let secrets = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return secrets
        }
    }
}
