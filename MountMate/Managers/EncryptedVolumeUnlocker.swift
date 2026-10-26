//  Created by homielab.com

import Foundation

/// The Keychain operations the unlock flow needs.
protocol UnlockPasswordStore: PasswordStore {
  func load(account: String) -> String?
  func savedAccounts() -> Set<String>
}

extension KeychainManager: UnlockPasswordStore {}

/// What `EncryptedVolumeUnlocker` needs from the manager that owns the drive
/// state: running `diskutil`, the busy spinner, refreshing the list, showing
/// an alert and the set of volumes with a saved password.
protocol EncryptedVolumeUnlockerHost: AnyObject {
  /// Runs `diskutil` with `input` on stdin. Blocking; called off the main thread.
  func runDiskUtil(arguments: [String], input: Data) -> ProcessResult
  func setBusy(_ volumeID: String, _ busy: Bool)
  func refreshDrives(qos: DispatchQoS.QoSClass, then completion: (() -> Void)?)
  /// Main thread.
  func showAlert(_ alert: AppAlert)
  /// Main thread. Reports a failure that is not a password problem.
  func reportUnlockFailure(_ result: ProcessResult, for volume: Volume)
  /// Main thread.
  func updateSavedPasswordIDs(_ change: SavedPasswordChange)
}

enum SavedPasswordChange: Equatable {
  case saved(String)
  case forgotten(String)
  case loaded(Set<String>)
}

/// What to do after `diskutil apfs unlockVolume` failed.
enum UnlockRetryDecision: Equatable {
  /// Ask for the password again. `passwordFailed` selects the "That password
  /// didn't work" wording; `logSavedPasswordFailure` marks a saved password
  /// that failed for a reason other than a rejected passphrase.
  case askAgain(passwordFailed: Bool, logSavedPasswordFailure: Bool)
  /// Show the generic mount error.
  case reportError

  /// - Parameters:
  ///   - result: the failed `diskutil` result.
  ///   - isSavedPassword: the attempt used the Keychain password, not a typed one.
  static func decide(result: ProcessResult, isSavedPassword: Bool) -> UnlockRetryDecision {
    let wrongPassphrase = DiskUtilErrorClassifier.isWrongPassphrase(result)
    if wrongPassphrase || (isSavedPassword && !result.timedOut) {
      return .askAgain(
        passwordFailed: wrongPassphrase, logSavedPasswordFailure: !wrongPassphrase)
    }
    return .reportError
  }
}

/// Unlocks encrypted APFS volumes: tries the saved Keychain password, asks
/// for one when needed, and saves it only after it worked. The passphrase
/// reaches `diskutil` through stdin only, never arguments or logs.
final class EncryptedVolumeUnlocker {
  private unowned let host: EncryptedVolumeUnlockerHost
  private let store: UnlockPasswordStore

  init(host: EncryptedVolumeUnlockerHost, store: UnlockPasswordStore = KeychainManager.shared) {
    self.host = host
    self.store = store
  }

  func mountLockedVolume(_ volume: Volume, passphrase: String, rememberPassphrase: Bool = false) {
    KeepAliveManager.shared.resume(volume: volume)
    let userInfo = ["deviceIdentifier": volume.id]
    NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    host.setBusy(volume.id, true)

    // The password the user just typed always wins over a saved one.
    DispatchQueue.global(qos: .userInitiated).async {
      self.performUnlock(
        volume: volume, passphrase: passphrase, isSavedPassword: false,
        rememberPassphrase: rememberPassphrase)
    }
  }

  /// Tries the keychain password for a locked volume without prompting.
  /// Returns false when there is no saved password.
  func unlockWithSavedPassword(_ volume: Volume) -> Bool {
    guard let saved = store.load(account: volume.id), !saved.isEmpty else {
      return false
    }
    KeepAliveManager.shared.resume(volume: volume)
    NotificationCenter.default.post(
      name: .willManuallyMount, object: nil, userInfo: ["deviceIdentifier": volume.id])
    host.setBusy(volume.id, true)
    DispatchQueue.global(qos: .userInitiated).async {
      self.performUnlock(volume: volume, passphrase: saved, isSavedPassword: true)
    }
    return true
  }

  /// Saves the passphrase the user asked to remember, but only once it has
  /// unlocked the volume, so a mistyped password is never stored.
  ///
  /// - Returns: nil when nothing was saved, otherwise the Keychain status.
  static func rememberPassphraseIfUnlocked(
    _ passphrase: String, for volume: Volume, unlocked: Bool, remember: Bool,
    store: PasswordStore
  ) -> OSStatus? {
    guard unlocked, remember else { return nil }
    return store.save(password: passphrase, for: volume.id, name: volume.name, kind: .apfsVolume)
  }

  /// Runs `diskutil apfs unlockVolume` (which also mounts the volume).
  /// Blocking; call off the main thread.
  private func performUnlock(
    volume: Volume, passphrase: String, isSavedPassword: Bool, rememberPassphrase: Bool = false
  ) {
    let result = host.runDiskUtil(
      arguments: ["apfs", "unlockVolume", volume.id, "-stdinpassphrase"],
      input: Data(passphrase.utf8))
    let saveStatus = Self.rememberPassphraseIfUnlocked(
      passphrase, for: volume, unlocked: result.succeeded, remember: rememberPassphrase,
      store: store)
    // Withdraw the single-use mount approval posted before unlocking, under
    // the same identifier, so it does not stay valid for its full lifetime.
    NotificationCenter.default.post(
      name: .didFinishManualMount, object: nil, userInfo: ["deviceIdentifier": volume.id])
    DispatchQueue.main.async {
      guard !result.succeeded else {
        if let saveStatus {
          self.handlePassphraseSaveResult(saveStatus, for: volume)
        }
        self.host.refreshDrives(qos: .userInitiated) { self.host.setBusy(volume.id, false) }
        return
      }
      self.host.setBusy(volume.id, false)
      switch UnlockRetryDecision.decide(result: result, isSavedPassword: isSavedPassword) {
      case .askAgain(let passwordFailed, let logSavedPasswordFailure):
        // A mistyped password, or a saved one that failed: ask again instead
        // of showing a generic error. "That password didn't work" only when
        // diskutil actually rejected the passphrase.
        if logSavedPasswordFailure {
          Log.drive.error("Unlock with saved password failed: \(result.stderr, privacy: .private)")
        }
        self.presentUnlockPrompt(for: volume, passwordFailed: passwordFailed)
      case .reportError:
        self.host.reportUnlockFailure(result, for: volume)
      }
      self.host.refreshDrives(qos: .userInitiated, then: nil)
    }
  }

  /// Main thread. Records a saved passphrase, or tells the user it could not
  /// be saved (the volume is unlocked either way).
  private func handlePassphraseSaveResult(_ status: OSStatus, for volume: Volume) {
    guard status != errSecSuccess else {
      host.updateSavedPasswordIDs(.saved(volume.id))
      return
    }
    host.showAlert(
      AppAlert(
        title: NSLocalizedString("Password Not Saved", comment: "Alert title"),
        message: String(
          format: NSLocalizedString(
            "“%@” is unlocked, but MountMate could not save its password to the Keychain (error %d).",
            comment: "Alert message: APFS unlock succeeded, Keychain save failed"),
          volume.name, status),
        kind: .basic))
  }

  /// Deletes the saved unlock password of an APFS volume.
  func forgetSavedPassword(for volume: Volume) {
    DispatchQueue.global(qos: .userInitiated).async {
      let status = self.store.delete(account: volume.id)
      DispatchQueue.main.async {
        guard status == errSecSuccess || status == errSecItemNotFound else {
          self.host.showAlert(
            AppAlert(
              title: NSLocalizedString("Action Failed", comment: "Alert title"),
              message: String(
                format: NSLocalizedString(
                  "MountMate could not remove the saved password from the Keychain (error %d).",
                  comment: "Keychain delete error"),
                status),
              kind: .basic))
          return
        }
        self.host.updateSavedPasswordIDs(.forgotten(volume.id))
      }
    }
  }

  /// Reads which volumes have a saved password, off the main thread.
  func loadSavedPasswordAccounts() {
    DispatchQueue.global(qos: .utility).async {
      let accounts = self.store.savedAccounts()
      DispatchQueue.main.async { self.host.updateSavedPasswordIDs(.loaded(accounts)) }
    }
  }

  /// Asks for the password of a locked APFS volume and unlocks it.
  func presentUnlockPrompt(for volume: Volume, passwordFailed: Bool) {
    let title = String(
      format: NSLocalizedString("“%@” is locked", comment: "Alert title"), volume.name)
    let message =
      passwordFailed
      ? String(
        format: NSLocalizedString(
          "That password didn’t work. Enter the password to unlock “%@”",
          comment: "Alert message after a wrong or outdated saved password"), volume.name)
      : String(
        format: NSLocalizedString(
          "Enter the password to unlock “%@”", comment: "Alert message"), volume.name)
    let handler = { (passphrase: String, saveInKeychain: Bool) in
      // Saved only after the unlock succeeds (see performUnlock).
      self.mountLockedVolume(volume, passphrase: passphrase, rememberPassphrase: saveInKeychain)
    }
    host.showAlert(
      AppAlert(
        title: title, message: message,
        kind: .lockedVolume(LockedVolumeAppAlert(onConfirm: handler))))
  }
}

extension DriveManager: EncryptedVolumeUnlockerHost {
  func runDiskUtil(arguments: [String], input: Data) -> ProcessResult {
    runProcess(
      executable: "/usr/sbin/diskutil", arguments: arguments, input: input,
      timeout: Self.mountUnmountTimeout)
  }

  func showAlert(_ alert: AppAlert) {
    userActionError = alert
  }

  func reportUnlockFailure(_ result: ProcessResult, for volume: Volume) {
    handleDiskUtilError(
      DiskUtilErrorClassifier.failureMessage(for: result, timeout: Self.mountUnmountTimeout),
      for: volume.name, volume: volume, operation: .mount)
  }

  func updateSavedPasswordIDs(_ change: SavedPasswordChange) {
    switch change {
    case .saved(let id): volumeIDsWithSavedPassword.insert(id)
    case .forgotten(let id): volumeIDsWithSavedPassword.remove(id)
    case .loaded(let ids): volumeIDsWithSavedPassword.formUnion(ids)
    }
  }
}
