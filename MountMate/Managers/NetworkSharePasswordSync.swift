//  Created by homielab.com

import Foundation
import Security

/// Keeps a network share's Keychain password in step with what the user
/// entered in the edit sheet.
struct NetworkSharePasswordSync {
  let store: PasswordStore

  /// Saves or removes the share's saved password. Returns a user-facing error
  /// message, or nil on success.
  /// - Parameters:
  ///   - share: the share as it will be saved.
  ///   - original: the share before editing, nil for a new one.
  ///   - password: the text in the password field.
  ///   - loadedPassword: the password read from the Keychain when editing, nil
  ///     when none was saved or it could not be read.
  func sync(
    share: NetworkShare, original: NetworkShare?, password: String, loadedPassword: String?
  ) -> String? {
    let account = share.id.uuidString
    guard share.shareProtocol.supportsUserCredentials else {
      // Switched to NFS, which uses no password: don't keep an orphaned one.
      guard let original, original.shareProtocol.supportsUserCredentials else { return nil }
      return deletePassword(account: account)
    }

    if !password.isEmpty {
      // Unchanged: skip the write (and any Keychain prompt it could cause).
      guard password != loadedPassword else { return nil }
      let status = store.save(
        password: password, for: account, name: share.name, kind: .networkShare)
      guard status == errSecSuccess else {
        return String(
          format: NSLocalizedString(
            "MountMate could not save the password to the Keychain (error %d).",
            comment: "Network share save error"),
          status)
      }
      return nil
    }

    // The field was emptied on edit: forget the saved password. Only when
    // one was actually loaded; if reading it failed, the empty field does
    // not mean the user cleared it.
    guard loadedPassword != nil else { return nil }
    return deletePassword(account: account)
  }

  private func deletePassword(account: String) -> String? {
    let status = store.delete(account: account)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      return String(
        format: NSLocalizedString(
          "MountMate could not remove the saved password from the Keychain (error %d).",
          comment: "Network share save error"),
        status)
    }
    return nil
  }
}
