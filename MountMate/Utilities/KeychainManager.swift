//  Created by homielab.com

import Foundation
import Security

class KeychainManager {
  static let shared = KeychainManager()
  private let serviceName = "com.homielab.mountmate"

  /// Outcome of reading a password, distinguishing "nothing saved" from a
  /// real failure (locked keychain, denied access, …).
  enum ReadResult {
    case found(String)
    case notFound
    case failed(OSStatus)
  }

  private init() {}

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
  }

  /// Saves (creates or replaces) the password for `account`.
  ///
  /// Updates the existing item in place and only adds a new one when none
  /// exists, so a failure can never lose the previously saved password (the
  /// old delete-then-add did when the add failed).
  ///
  /// - Returns: `errSecSuccess` on success, otherwise the Keychain error.
  @discardableResult
  func save(password: String, for account: String) -> OSStatus {
    let data = Data(password.utf8)
    let query = baseQuery(account: account)

    let updateStatus = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard updateStatus == errSecItemNotFound else { return updateStatus }

    var addQuery = query
    addQuery[kSecValueData as String] = data
    return SecItemAdd(addQuery as CFDictionary, nil)
  }

  /// Reads the password for `account`.
  func read(account: String) -> ReadResult {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var dataTypeRef: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

    switch status {
    case errSecSuccess:
      guard let data = dataTypeRef as? Data, let password = String(data: data, encoding: .utf8)
      else { return .failed(errSecDecode) }
      return .found(password)
    case errSecItemNotFound:
      return .notFound
    default:
      return .failed(status)
    }
  }

  /// Convenience for callers that treat any failure as "no password".
  func load(account: String) -> String? {
    if case .found(let password) = read(account: account) {
      return password
    }
    return nil
  }

  /// Deletes the password for `account`.
  ///
  /// - Returns: `errSecSuccess`, `errSecItemNotFound` when nothing was saved,
  ///   or another Keychain error.
  @discardableResult
  func delete(account: String) -> OSStatus {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
  }
}
