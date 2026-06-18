import Foundation
import Security

/// 把 API key 存進 macOS Keychain（取代明文 UserDefaults）。
enum KeychainStore {

  private static let service = "com.morpheus.quill"
  private static let account = "openai_api_key"

  /// 舊版明文儲存的 UserDefaults key，首次讀取時自動搬移
  private static let legacyDefaultsKey = "quill_api_key"

  static var apiKey: String {
    get {
      if let key = read(), !key.isEmpty { return key }
      // 一次性搬移：舊版存在 UserDefaults 的 key
      if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
        write(legacy)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return legacy
      }
      return ""
    }
    set {
      if newValue.isEmpty {
        delete()
      } else {
        write(newValue)
      }
      // 確保舊的明文副本被清掉
      UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }
  }

  // MARK: - Keychain primitives

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String:       kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func read() -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  private static func write(_ value: String) -> Bool {
    let data = Data(value.utf8)

    // 先嘗試更新既有項目
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return true }

    // 不存在則新增
    var query = baseQuery
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }

  private static func delete() {
    SecItemDelete(baseQuery as CFDictionary)
  }
}
