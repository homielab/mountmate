//  Created by homielab.com

import Foundation

/// The Keychain operations the unlock flow needs.
protocol UnlockPasswordStore: PasswordStore {
  func read(account: String) -> KeychainManager.ReadResult
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
  /// Too many typed passwords were rejected: stop asking and say what to check.
  case giveUp

  /// Typed passwords diskutil may reject before MountMate stops asking.
  static let maxTypedAttempts = 3

  /// - Parameters:
  ///   - result: the failed `diskutil` result.
  ///   - isSavedPassword: the attempt used the Keychain password, not a typed one.
  ///   - typedFailures: typed passwords tried since the prompt first opened,
  ///     counting this one. A rejected saved password does not count.
  static func decide(
    result: ProcessResult, isSavedPassword: Bool, typedFailures: Int = 1
  ) -> UnlockRetryDecision {
    let wrongPassphrase = DiskUtilErrorClassifier.isWrongPassphrase(result)
    if wrongPassphrase && !isSavedPassword && typedFailures >= maxTypedAttempts {
      return .giveUp
    }
    if wrongPassphrase || (isSavedPassword && !result.timedOut) {
      return .askAgain(
        passwordFailed: wrongPassphrase, logSavedPasswordFailure: !wrongPassphrase)
    }
    return .reportError
  }
}

/// Whether an automatic or bulk mount that found a volume locked tries its
/// saved Keychain password, silently and once.
enum SilentUnlockRules {
  /// - Parameters:
  ///   - mountFailedLocked: the mount failed only because the volume is locked.
  ///   - hasSavedPassword: a Keychain password is saved for the volume.
  ///   - savedPasswordRejected: diskutil already rejected that password; it is
  ///     not tried again until the user unlocks the volume by hand.
  static func shouldTrySavedPassword(
    mountFailedLocked: Bool, hasSavedPassword: Bool, savedPasswordRejected: Bool
  ) -> Bool {
    mountFailedLocked && hasSavedPassword && !savedPasswordRejected
  }
}

/// Unlocks encrypted APFS volumes: tries the saved Keychain password, asks
/// for one when needed, and saves it only after it worked. The passphrase
/// reaches `diskutil` through stdin only, never arguments or logs.
final class EncryptedVolumeUnlocker {
  private unowned let host: EncryptedVolumeUnlockerHost
  private let store: UnlockPasswordStore
  /// Main thread only. Typed passwords rejected so far, per volume.
  private var typedFailures: [String: Int] = [:]
  /// Main thread only. Volumes whose saved password diskutil rejected.
  private var rejectedSavedPasswords: Set<String> = []

  init(host: EncryptedVolumeUnlockerHost, store: UnlockPasswordStore = KeychainManager.shared) {
    self.host = host
    self.store = store
  }

  func mountLockedVolume(
    _ volume: Volume, passphrase: String, rememberPassphrase: Bool = false,
    forgetSavedPassword: Bool = false
  ) {
    KeepAliveManager.shared.resume(volume: volume)
    let userInfo = ["deviceIdentifier": volume.id]
    NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    host.setBusy(volume.id, true)

    // The password the user just typed always wins over a saved one.
    DispatchQueue.global(qos: .userInitiated).async {
      self.performUnlock(
        volume: volume, passphrase: passphrase, isSavedPassword: false,
        rememberPassphrase: rememberPassphrase, forgetSavedPassword: forgetSavedPassword)
    }
  }

  /// Tries the keychain password for a locked volume without prompting.
  /// Returns false when nothing was tried: no saved password (the saved
  /// badge is cleared if it was deleted outside MountMate), or the Keychain
  /// could not be read, in which case the password prompt says why.
  func unlockWithSavedPassword(_ volume: Volume) -> Bool {
    let saved: String
    switch store.read(account: volume.id) {
    case .found(let password) where !password.isEmpty:
      saved = password
    case .found, .notFound:
      host.updateSavedPasswordIDs(.forgotten(volume.id))
      return false
    case .failed(let status):
      Log.drive.error("Could not read the saved password from the Keychain (\(status))")
      presentUnlockPrompt(for: volume, passwordFailed: false, keychainError: status)
      return true
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

  /// Main thread. Tries the saved Keychain password of a volume that an
  /// automatic or bulk mount (Keep Alive, Mount Again on Wake, Mount All,
  /// Shortcuts) found locked, without ever prompting or showing an alert. A
  /// rejected password is remembered and not tried again until a manual
  /// unlock succeeds, so a sweep does not retry it every 30 seconds.
  ///
  /// - Parameter approvesMount: post the single-use mount approval, for
  ///   mounts the user asked for (Mount All, Shortcuts).
  /// - Parameter completion: Main thread; true when the volume was unlocked
  ///   (and mounted). Called synchronously when nothing is tried.
  func unlockSilently(
    _ volume: Volume, afterMount mountResult: ProcessResult, hasSavedPassword: Bool,
    approvesMount: Bool, completion: @escaping (Bool) -> Void
  ) {
    guard
      SilentUnlockRules.shouldTrySavedPassword(
        mountFailedLocked: DiskUtilErrorClassifier.isLockedVolumeFailure(mountResult),
        hasSavedPassword: hasSavedPassword,
        savedPasswordRejected: rejectedSavedPasswords.contains(volume.id))
    else {
      completion(false)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let read = self.store.read(account: volume.id)
      guard case .found(let saved) = read, !saved.isEmpty else {
        DispatchQueue.main.async {
          if case .failed(let status) = read {
            Log.drive.error("Could not read the saved password from the Keychain (\(status))")
          } else {
            self.host.updateSavedPasswordIDs(.forgotten(volume.id))
          }
          completion(false)
        }
        return
      }
      let userInfo = ["deviceIdentifier": volume.id]
      if approvesMount {
        NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
      }
      let result = self.host.runDiskUtil(
        arguments: ["apfs", "unlockVolume", volume.deviceIdentifier, "-stdinpassphrase"],
        input: Data(saved.utf8))
      if approvesMount {
        NotificationCenter.default.post(
          name: .didFinishManualMount, object: nil, userInfo: userInfo)
      }
      DispatchQueue.main.async {
        if result.succeeded {
          self.rejectedSavedPasswords.remove(volume.id)
        } else if DiskUtilErrorClassifier.isWrongPassphrase(result) {
          self.rejectedSavedPasswords.insert(volume.id)
          Log.drive.notice(
            "Saved password of a locked volume was rejected; not retried until unlocked by hand")
        } else {
          Log.drive.error(
            "Silent unlock with saved password failed: \(result.stderr, privacy: .private)")
        }
        completion(result.succeeded)
      }
    }
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
    volume: Volume, passphrase: String, isSavedPassword: Bool, rememberPassphrase: Bool = false,
    forgetSavedPassword: Bool = false
  ) {
    let result = host.runDiskUtil(
      arguments: ["apfs", "unlockVolume", volume.deviceIdentifier, "-stdinpassphrase"],
      input: Data(passphrase.utf8))
    let saveStatus = Self.rememberPassphraseIfUnlocked(
      passphrase, for: volume, unlocked: result.succeeded, remember: rememberPassphrase,
      store: store)
    // A typed password worked while the saved one was rejected: the saved
    // one is stale. Remembering replaced it above; otherwise forget it only
    // when the user ticked the box.
    var forgotten = false
    if result.succeeded, forgetSavedPassword, !rememberPassphrase {
      let status = store.delete(account: volume.id)
      forgotten = status == errSecSuccess || status == errSecItemNotFound
    }
    // Withdraw the single-use mount approval posted before unlocking, under
    // the same identifier, so it does not stay valid for its full lifetime.
    NotificationCenter.default.post(
      name: .didFinishManualMount, object: nil, userInfo: ["deviceIdentifier": volume.id])
    DispatchQueue.main.async {
      guard !result.succeeded else {
        self.typedFailures[volume.id] = nil
        self.rejectedSavedPasswords.remove(volume.id)
        if forgotten { self.host.updateSavedPasswordIDs(.forgotten(volume.id)) }
        if let saveStatus {
          self.handlePassphraseSaveResult(saveStatus, for: volume)
        }
        self.host.refreshDrives(qos: .userInitiated) { self.host.setBusy(volume.id, false) }
        return
      }
      self.host.setBusy(volume.id, false)
      let wrongPassphrase = DiskUtilErrorClassifier.isWrongPassphrase(result)
      if isSavedPassword {
        // Only a confirmed rejection marks it stale; a timeout never does.
        if wrongPassphrase { self.rejectedSavedPasswords.insert(volume.id) }
      } else if wrongPassphrase {
        self.typedFailures[volume.id, default: 0] += 1
      }
      let decision = UnlockRetryDecision.decide(
        result: result, isSavedPassword: isSavedPassword,
        typedFailures: self.typedFailures[volume.id] ?? 0)
      switch decision {
      case .askAgain(let passwordFailed, let logSavedPasswordFailure):
        // A mistyped password, or a saved one that failed: ask again instead
        // of showing a generic error. "That password didn't work" only when
        // diskutil actually rejected the passphrase.
        if logSavedPasswordFailure {
          Log.drive.error("Unlock with saved password failed: \(result.stderr, privacy: .private)")
        }
        self.presentUnlockPrompt(for: volume, passwordFailed: passwordFailed)
      case .reportError:
        self.typedFailures[volume.id] = nil
        self.host.reportUnlockFailure(result, for: volume)
      case .giveUp:
        self.typedFailures[volume.id] = nil
        self.presentGiveUp(for: volume)
      }
      self.host.refreshDrives(qos: .userInitiated, then: nil)
    }
  }

  /// Main thread. Tells the user MountMate stopped asking for a password.
  private func presentGiveUp(for volume: Volume) {
    host.showAlert(
      AppAlert(
        title: String(
          format: NSLocalizedString(
            "Could not unlock “%@”", comment: "Alert title: too many wrong passwords"),
          volume.name),
        message: String(
          format: NSLocalizedString(
            "The password was not accepted %d times. Check that Caps Lock is off and the keyboard layout is the one you used when you set the password, or try unlocking the volume in Disk Utility.",
            comment: "Alert message after repeated wrong passwords"),
          UnlockRetryDecision.maxTypedAttempts),
        kind: .basic))
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
  ///
  /// - Parameter keychainError: the saved password could not be read (locked
  ///   Keychain, access denied); the message says so instead of asking again
  ///   without a reason.
  func presentUnlockPrompt(
    for volume: Volume, passwordFailed: Bool, keychainError: OSStatus? = nil
  ) {
    let title = String(
      format: NSLocalizedString("“%@” is locked", comment: "Alert title"), volume.name)
    let message =
      keychainError.map { status in
        String(
          format: NSLocalizedString(
            "MountMate could not read the saved password from the Keychain (error %d). Enter the password to unlock “%@”",
            comment:
              "Alert message: Keychain locked or access denied when reading the saved APFS password"
          ),
          status, volume.name)
      }
      ?? (passwordFailed
        ? String(
          format: NSLocalizedString(
            "That password didn’t work. Enter the password to unlock “%@”",
            comment: "Alert message after a wrong or outdated saved password"), volume.name)
        : String(
          format: NSLocalizedString(
            "Enter the password to unlock “%@”", comment: "Alert message"), volume.name))
    if !passwordFailed { typedFailures[volume.id] = nil }
    let offersForget = rejectedSavedPasswords.contains(volume.id)
    let handler = { (passphrase: String, saveInKeychain: Bool, forgetSaved: Bool) in
      // Saved or forgotten only after the unlock succeeds (see performUnlock).
      self.mountLockedVolume(
        volume, passphrase: passphrase, rememberPassphrase: saveInKeychain,
        forgetSavedPassword: forgetSaved && offersForget)
    }
    host.showAlert(
      AppAlert(
        title: title, message: message,
        kind: .lockedVolume(
          LockedVolumeAppAlert(offersForgetSavedPassword: offersForget, onConfirm: handler))))
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
    case .loaded(let ids): volumeIDsWithSavedPassword = ids
    }
  }
}
