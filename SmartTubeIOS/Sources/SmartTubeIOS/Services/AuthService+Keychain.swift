import Foundation

extension AuthService {

    // MARK: - Persistence (Keychain)

    func saveToKeychain() {
        keychainSet(key: tokenKey,   value: accessToken)
        keychainSet(key: refreshKey, value: refreshToken)
        keychainSet(key: expiryKey,  value: tokenExpiry.map { ISO8601DateFormatter().string(from: $0) })
        keychainSet(key: accountKey, value: accountName)
        keychainSet(key: avatarKey,  value: accountAvatarURL?.absoluteString)
    }

    func loadFromKeychain() {
        accessToken      = keychainGet(key: tokenKey)
        refreshToken     = keychainGet(key: refreshKey)
        if let expiryStr = keychainGet(key: expiryKey) {
            tokenExpiry  = ISO8601DateFormatter().date(from: expiryStr)
        }
        accountName      = keychainGet(key: accountKey)
        accountAvatarURL = keychainGet(key: avatarKey).flatMap { URL(string: $0) }
        // If the stored access token has already expired, clear it so that
        // view observers (e.g. HomeView.task(id: auth.accessToken)) don't fire
        // API requests with a stale token. scheduleProactiveRefresh() will
        // obtain a fresh token and set accessToken once it succeeds.
        if let expiry = tokenExpiry, expiry <= Date() {
            accessToken = nil
        }
        isSignedIn       = accessToken != nil || refreshToken != nil
        if isSignedIn { scheduleProactiveRefresh() }
    }

    func clearKeychain() {
        [tokenKey, refreshKey, expiryKey, accountKey, avatarKey].forEach { keychainDelete(key: $0) }
    }

    // MARK: - Keychain helpers

    func keychainSet(key: String, value: String?) {
        // Always delete the existing item first to avoid errSecDuplicateItem
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard let value, let valueData = value.data(using: .utf8) else { return }
        let addQuery: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    keychainService,
            kSecAttrAccount:    key,
            kSecValueData:      valueData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            authLog.error("keychainSet failed for key=\(key) status=\(status)")
        }
    }

    func keychainGet(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  keychainService,
            kSecAttrAccount:  key,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func keychainDelete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
