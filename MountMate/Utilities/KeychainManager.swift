//  Created by homielab.com

import Foundation
import Security

class KeychainManager {
  static let shared = KeychainManager()
  private let serviceName = "com.homielab.mountmate"

  private init() {}

  func save(password: String, for account: String) -> OSStatus {
    let data = password.data(using: .utf8)!
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
    ]

    SecItemDelete(query as CFDictionary)
    return SecItemAdd(query as CFDictionary, nil)
  }

  func load(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var dataTypeRef: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

    if status == errSecSuccess, let data = dataTypeRef as? Data {
      return String(data: data, encoding: .utf8)
    }
    return nil
  }

  func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
