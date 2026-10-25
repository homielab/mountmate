//  Created by homielab.com

import Foundation
import Security

/// What a saved password unlocks. Shown as the item's kind in Keychain Access.
enum KeychainItemKind {
  case apfsVolume
  case networkShare

  var itemDescription: String {
    switch self {
    case .apfsVolume: return "APFS volume"
    case .networkShare: return "Network share"
    }
  }
}

/// The password operations MountMate needs, so callers can be tested
/// without touching the real Keychain.
protocol PasswordStore {
  @discardableResult
  func save(password: String, for account: String, name: String, kind: KeychainItemKind)
    -> OSStatus
  @discardableResult
  func delete(account: String) -> OSStatus
}

class KeychainManager: PasswordStore {
  static let shared = KeychainManager()
  static let serviceName = "com.homielab.mountmate"

  /// Outcome of reading a password, distinguishing "nothing saved" from a
  /// real failure (locked keychain, denied access, …).
  enum ReadResult {
    case found(String)
    case notFound
    case failed(OSStatus)
  }

  private init() {}

  /// Finds an item by service and account only. Label and description are
  /// deliberately left out, so items saved by older versions (which had
  /// neither) are still found, updated and deleted.
  static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
  }

  /// The label shown in Keychain Access, e.g. "MountMate – Backup".
  static func itemLabel(name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "MountMate" : "MountMate – \(trimmed)"
  }

  /// Label and description written with every save, so an old unlabeled
  /// item gets them the next time its password is saved.
  static func displayAttributes(name: String, kind: KeychainItemKind) -> [String: Any] {
    [
      kSecAttrLabel as String: itemLabel(name: name),
      kSecAttrDescription as String: kind.itemDescription,
    ]
  }

  /// Saves (creates or replaces) the password for `account`, labeled with
  /// `name` and `kind` so the item is recognizable in Keychain Access.
  ///
  /// Updates the existing item in place and only adds a new one when none
  /// exists, so a failure can never lose the previously saved password (the
  /// old delete-then-add did when the add failed).
  ///
  /// - Returns: `errSecSuccess` on success, otherwise the Keychain error.
  @discardableResult
  func save(password: String, for account: String, name: String, kind: KeychainItemKind)
    -> OSStatus
  {
    let query = Self.baseQuery(account: account)
    var attributes = Self.displayAttributes(name: name, kind: kind)
    attributes[kSecValueData as String] = Data(password.utf8)

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    guard updateStatus == errSecItemNotFound else { return updateStatus }

    let addQuery = query.merging(attributes) { _, new in new }
    return SecItemAdd(addQuery as CFDictionary, nil)
  }

  /// Reads the password for `account`.
  func read(account: String) -> ReadResult {
    var query = Self.baseQuery(account: account)
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

  /// The accounts that have a saved password. Reads attributes only, never
  /// the passwords, so it does not trigger a Keychain access prompt.
  func savedAccounts() -> Set<String> {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.serviceName,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let items = result as? [[String: Any]]
    else { return [] }
    return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
  }

  /// Deletes the password for `account`.
  ///
  /// - Returns: `errSecSuccess`, `errSecItemNotFound` when nothing was saved,
  ///   or another Keychain error.
  @discardableResult
  func delete(account: String) -> OSStatus {
    SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
  }
}
