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

    // Without a username the mount passes no credentials (the Mac's own
    // login, then guest), so a password would be saved but never used.
    if share.username.isEmpty {
      guard loadedPassword != nil else { return nil }
      return deletePassword(account: account)
    }

    if !password.isEmpty {
      // Unchanged: skip the write (and any Keychain prompt it could cause),
      // but keep the Keychain Access label in step with a new name.
      guard password != loadedPassword else {
        relabelIfRenamed(share: share, original: original, account: account)
        return nil
      }
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

  /// The label is cosmetic: a failure is logged, never shown.
  private func relabelIfRenamed(share: NetworkShare, original: NetworkShare?, account: String) {
    guard let original, original.name != share.name else { return }
    let status = store.updateLabel(for: account, name: share.name, kind: .networkShare)
    if status != errSecSuccess {
      Log.persistence.error(
        "Could not relabel the Keychain item of a renamed share (status \(status, privacy: .public))."
      )
    }
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
