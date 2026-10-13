import Foundation
import Security

/// 把 API key 存進 macOS Keychain（取代明文 UserDefaults）。
enum KeychainStore {

  private static let service = "com.morpheus.quill"
  private static let apiKeyAccount = "openai_api_key"
  private static let cloudTokenAccount = "cloud_installation_token"
  private static let cloudTokenFallbackKey = "quill_cloud_installation_token_fallback"

  /// 舊版明文儲存的 UserDefaults key，首次讀取時自動搬移
  private static let legacyDefaultsKey = "quill_api_key"

  static var apiKey: String {
    get {
      loadAPIKey(read: { read(account: apiKeyAccount) },
                 legacy: { UserDefaults.standard.string(forKey: legacyDefaultsKey) },
                 write: { write($0, account: apiKeyAccount) },
                 removeLegacy: { UserDefaults.standard.removeObject(forKey: legacyDefaultsKey) })
    }
    set {
      _ = saveAPIKey(newValue)
    }
  }

  @discardableResult
  static func saveAPIKey(_ value: String) -> Bool {
    saveAPIKey(value, write: { write($0, account: apiKeyAccount) },
               delete: { delete(account: apiKeyAccount) },
               removeLegacy: { UserDefaults.standard.removeObject(forKey: legacyDefaultsKey) })
  }

  // Inject storage operations so migration and failure handling can be tested without credentials.
  static func loadAPIKey(read: () -> String?, legacy: () -> String?,
                         write: (String) -> Bool, removeLegacy: () -> Void) -> String {
    if let key = read(), !key.isEmpty { return key }
    guard let old = legacy(), !old.isEmpty else { return "" }
    if write(old) { removeLegacy() }
    return old
  }

  @discardableResult
  static func saveAPIKey(_ value: String, write: (String) -> Bool,
                         delete: () -> Bool, removeLegacy: () -> Void) -> Bool {
    let succeeded = value.isEmpty ? delete() : write(value)
    if succeeded { removeLegacy() }
    return succeeded
  }

  static var cloudInstallationToken: String {
    get {
      if let token = read(account: cloudTokenAccount), !token.isEmpty {
        return token
      }
      guard
        let fallback = UserDefaults.standard.string(forKey: cloudTokenFallbackKey),
        !fallback.isEmpty
      else { return "" }

      // 新建立的 macOS 使用者可能尚未有 login keychain。之後 keychain 可用時再搬回。
      if write(fallback, account: cloudTokenAccount) {
        UserDefaults.standard.removeObject(forKey: cloudTokenFallbackKey)
      }
      return fallback
    }
    set {
      if newValue.isEmpty {
        delete(account: cloudTokenAccount)
        UserDefaults.standard.removeObject(forKey: cloudTokenFallbackKey)
      } else {
        if write(newValue, account: cloudTokenAccount) {
          UserDefaults.standard.removeObject(forKey: cloudTokenFallbackKey)
        } else {
          // 這是匿名安裝 token，不是使用者 API key。沒有 login keychain 時採本機 fallback，
          // 避免 macOS 顯示「Keychain Not Found」並阻斷第一次 API 請求。
          UserDefaults.standard.set(newValue, forKey: cloudTokenFallbackKey)
        }
      }
    }
  }

  // MARK: - Keychain primitives

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func read(account: String) -> String? {
    guard defaultKeychainAvailable else { return nil }
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  private static func write(_ value: String, account: String) -> Bool {
    guard defaultKeychainAvailable else { return false }
    let data = Data(value.utf8)
    let query = baseQuery(account: account)

    // 先嘗試更新既有項目
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return true }

    guard updateStatus == errSecItemNotFound else { return false }
    // 不存在則新增
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
  }

  @discardableResult
  private static func delete(account: String) -> Bool {
    guard defaultKeychainAvailable else { return false }
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }

  /// 剛建立、尚未完成首次登入初始化的標準使用者可能沒有預設 login keychain。
  /// 先檢查可用性，避免 SecItemAdd 自己跳出阻斷式系統錯誤視窗。
  private static var defaultKeychainAvailable: Bool {
    var keychain: SecKeychain?
    return SecKeychainCopyDefault(&keychain) == errSecSuccess && keychain != nil
  }
}
