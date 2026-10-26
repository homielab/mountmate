//  Created by homielab.com

import Foundation
import NetFS

/// What `NetworkShareMounter` needs from the manager that owns the share
/// state: where a share mounts, the kernel mount table, which mounts are a
/// share's, adopting a mount, and refreshing the published status.
protocol NetworkShareMounterHost: AnyObject {
  func configuredMountPoint(for share: NetworkShare) -> String
  func currentMountTable() -> [MountedNetworkShare]?
  func mounts(of share: NetworkShare, in mountTable: [MountedNetworkShare])
    -> [MountedNetworkShare]
  func adopt(_ mountPoint: String, for share: NetworkShare)
  func refreshMountStatus(completion: (() -> Void)?)
}

/// What to do once the protocol-specific mount step has finished: the result
/// handed to the waiting callers and whether the mount point folder MountMate
/// created is removed or the mount is undone.
struct MountResolution: Equatable {
  let success: Bool
  let message: String?
  /// Remove the mount point folder MountMate created for this attempt.
  let cleanUpMountPoint: Bool
  /// Unmount again: an automatic mount landed after the user ejected the share.
  let undoMount: Bool
}

/// Mounts saved network shares (SMB/AFP through NetFS, NFS through
/// `mount_nfs`) and tracks in-flight and stalled mount attempts.
final class NetworkShareMounter {
  private unowned let host: NetworkShareMounterHost

  /// Completions waiting on an in-flight mount, keyed by share ID. Login
  /// auto-mount, keep-alive sweeps (launch, wake, network change) and manual
  /// clicks can all ask for the same share at once; only one mount_* process
  /// may run per share, the rest piggyback on its result.
  private var pendingMountCompletions: [UUID: [(Bool, String?) -> Void]] = [:]
  /// Shares whose NetFS mount call outlived `netFSMountTimeout` and is still
  /// running in the background (NetFS calls cannot be cancelled). New
  /// attempts for such a share fail fast instead of stacking a second mount
  /// onto the same folder. Guarded by `mountLock`.
  private var stalledMounts: [UUID: StalledMount] = [:]
  private let mountLock = NSLock()

  /// After this long, a user-initiated mount may start even though an
  /// earlier NetFS call for the share never returned (it may never). Keep-
  /// alive keeps waiting, so automatic mounts never run concurrently.
  static let stalledMountRetryAge: TimeInterval = 150

  /// NetFS has no timeout of its own and can block for a long time on an
  /// unreachable server. The mount is abandoned (reported as timed out)
  /// after this long so the UI and keep-alive sweeps never get stuck.
  private static let netFSMountTimeout: TimeInterval = 30

  init(host: NetworkShareMounterHost) {
    self.host = host
  }

  /// Mounts a saved share. Concurrent requests for the same share share one
  /// mount operation and its result.
  ///
  /// - Parameter userInitiated: `true` when the user asked for this mount
  ///   (menu or Settings). Only such mounts clear keep-alive suppression and
  ///   retry/backoff state. Automatic mounts (login, keep-alive, network
  ///   change) pass `false`: clearing the retry state on every keep-alive
  ///   attempt would reset the backoff each time, and an automatic mount must
  ///   never undo the user's own eject.
  func mount(
    share: NetworkShare, userInitiated: Bool = true,
    completion: @escaping (Bool, String?) -> Void
  ) {
    if userInitiated {
      KeepAliveManager.shared.resume(shareID: share.id)
    } else if KeepAliveManager.shared.isSuppressed(shareID: share.id) {
      // The user ejected this share in MountMate after the automatic mount
      // was scheduled: respect that.
      DispatchQueue.main.async { completion(false, nil) }
      return
    }

    mountLock.lock()
    if pendingMountCompletions[share.id] != nil {
      pendingMountCompletions[share.id]?.append(completion)
      mountLock.unlock()
      return
    }
    pendingMountCompletions[share.id] = [completion]
    mountLock.unlock()

    let finish: (Bool, String?) -> Void = { [weak self] success, error in
      guard let self else { return }
      self.mountLock.lock()
      let waiters = self.pendingMountCompletions.removeValue(forKey: share.id) ?? []
      self.mountLock.unlock()
      DispatchQueue.main.async {
        for completion in waiters { completion(success, error) }
      }
    }

    // Everything below can block (`mount_nfs`, the Keychain, NetFS), so
    // keep it all off the main thread and the menu never freezes.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      self.performMount(share: share, userInitiated: userInitiated, finish: finish)
    }
  }

  /// Result of the protocol-specific mount step.
  enum MountOutcome: Equatable {
    case success
    /// `mayStillComplete`: the mount call is still running in the background
    /// and may yet mount the share, so the mount point must be left alone.
    case timedOut(mayStillComplete: Bool)
    /// NetFS reported the share as already mounted, and the mount table
    /// showed it under another form of the server name; that mount was
    /// adopted as this share's. Our own (unused) folder can be cleaned up.
    case adopted
    /// A user-readable error message.
    case failed(String)
  }

  /// Blocking part of `mount(share:completion:)`. Must not run on the main
  /// thread. `finish` delivers its result on the main thread.
  private func performMount(
    share: NetworkShare, userInitiated: Bool, finish: @escaping (Bool, String?) -> Void
  ) {
    let mountPoint = host.configuredMountPoint(for: share)

    // An earlier NetFS call for this share timed out and is still running.
    // Automatic mounts always wait for it (no concurrent mounts onto the
    // same folder); the user may retry once it is old enough, since a call
    // that never returns would otherwise block the share all session.
    if let stall = mountLock.withLock({ stalledMounts[share.id] }) {
      let age = Date().timeIntervalSince(stall.since)
      guard !Self.shouldBlock(stallAge: age, userInitiated: userInitiated) else {
        finish(
          false,
          String(
            format: NSLocalizedString(
              "A previous connection attempt to “%@” is still in progress.",
              comment: "Network share mount error"),
            share.name))
        return
      }
      Log.network.notice(
        "Retrying \(share.name, privacy: .private) although an earlier NetFS call is stalled (\(Int(age), privacy: .public)s)."
      )
    }

    // Decide "already mounted" from the kernel mount table only. stat() and
    // other file checks on a mount point whose server stopped responding can
    // block indefinitely (which used to wedge keep-alive sweeps).
    let mountTable = host.currentMountTable()

    // Already mounted (at our target path or elsewhere)?
    if let existingMount = mountTable.flatMap({ host.mounts(of: share, in: $0).first }) {
      Log.network.info(
        "Share \(share.name, privacy: .private) is already mounted at \(existingMount.mountPoint, privacy: .private)"
      )
      host.refreshMountStatus(completion: nil)
      finish(true, nil)
      return
    }

    // Our target folder may be occupied by a DIFFERENT share (e.g. two saved
    // shares with the same name). Never report that as success, and never
    // mount on top of it.
    if let occupant = mountTable?.first(where: {
      NetworkMountManager.samePath($0.mountPoint, mountPoint)
    }) {
      finish(
        false,
        String(
          format: NSLocalizedString(
            "“%@” cannot be mounted at “%@” because another share (%@) is already mounted there.",
            comment: "Network share mount error: mount point used by another share"),
          share.name, mountPoint, redactingURLPasswords(occupant.source)))
      return
    }

    // Let's try creating the directory first.
    var createdMountPoint = false
    do {
      if !FileManager.default.fileExists(atPath: mountPoint) {
        try FileManager.default.createDirectory(
          atPath: mountPoint, withIntermediateDirectories: true)
        createdMountPoint = true
      }
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain
        && (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileNoSuchFileError)
      {
        finish(
          false,
          String(
            format: NSLocalizedString(
              "Cannot create mount point at “%1$@”.\n\nThis location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/%2$@) or leave the Custom Mount Point empty to use the default location.",
              comment: "Network share mount error: 1 = mount point path, 2 = share name"),
            mountPoint, share.name))
      } else {
        finish(
          false,
          String(
            format: NSLocalizedString(
              "Failed to create mount point at “%1$@”: %2$@",
              comment: "Network share mount error: 1 = mount point path, 2 = system error"),
            mountPoint, error.localizedDescription))
      }
      return
    }

    let outcome: MountOutcome
    switch share.shareProtocol {
    case .nfs:
      outcome = runNFSMount(share: share, mountPoint: mountPoint)
    case .smb, .afp:
      // Read the Keychain only now that a mount really happens, so shares
      // that are already mounted never trigger a Keychain access prompt.
      let password: String?
      switch KeychainManager.shared.read(account: share.id.uuidString) {
      case .found(let savedPassword):
        password = savedPassword
      case .notFound:
        password = nil
      case .failed(let status):
        // Do not fall back to an empty password: that would turn a
        // Keychain problem into a confusing authentication failure (or a
        // guest connection).
        cleanUpMountPoint(mountPoint, ifCreated: createdMountPoint)
        finish(
          false,
          String(
            format: NSLocalizedString(
              "MountMate could not read the saved password for “%@” from the Keychain (error %d).",
              comment: "Network share mount error: keychain read failed"),
            share.name, status))
        return
      }
      outcome = runNetFSMount(
        share: share, password: password, mountPoint: mountPoint, userInitiated: userInitiated)
    }

    let isSuppressed = KeepAliveManager.shared.isSuppressed(shareID: share.id)
    let resolution = Self.resolution(
      for: outcome, share: share, userInitiated: userInitiated, isSuppressed: isSuppressed)
    if resolution.undoMount {
      // The user ejected this share in MountMate while this automatic
      // mount was in flight: undo it.
      Log.network.notice(
        "Unmounting \(share.name, privacy: .private) again: it was ejected during an automatic mount."
      )
      logUndoUnmount(of: share, at: mountPoint)
    }
    if resolution.cleanUpMountPoint {
      cleanUpMountPoint(mountPoint, ifCreated: createdMountPoint)
    }
    host.refreshMountStatus { finish(resolution.success, resolution.message) }
  }

  /// Turns the result of the protocol-specific step into what the callers
  /// hear and which clean-up follows. An automatic mount that succeeded
  /// although the user ejected the share meanwhile (`isSuppressed`) is
  /// undone and reported as not mounted, without a message. A timeout leaves
  /// the folder alone while the call may still complete.
  static func resolution(
    for outcome: MountOutcome, share: NetworkShare, userInitiated: Bool, isSuppressed: Bool
  ) -> MountResolution {
    switch outcome {
    case .success:
      if !userInitiated && isSuppressed {
        return MountResolution(
          success: false, message: nil, cleanUpMountPoint: true, undoMount: true)
      }
      return MountResolution(
        success: true, message: nil, cleanUpMountPoint: false, undoMount: false)
    case .adopted:
      return MountResolution(success: true, message: nil, cleanUpMountPoint: true, undoMount: false)
    case .timedOut(let mayStillComplete):
      return MountResolution(
        success: false, message: timeoutMessage(for: share),
        cleanUpMountPoint: !mayStillComplete, undoMount: false)
    case .failed(let message):
      return MountResolution(
        success: false, message: message, cleanUpMountPoint: true, undoMount: false)
    }
  }

  /// Whether a mount attempt must fail fast because an earlier NetFS call for
  /// the share has been stalled for `stallAge` seconds. Automatic mounts
  /// always wait; the user may retry once the stall is old enough.
  static func shouldBlock(stallAge: TimeInterval, userInitiated: Bool) -> Bool {
    !(userInitiated && stallAge >= stalledMountRetryAge)
  }

  /// Unmounts a share an automatic mount left behind after the user ejected it
  /// meanwhile; a failure (busy share) is logged instead of ignored.
  private func logUndoUnmount(of share: NetworkShare, at mountPoint: String) {
    let result = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
    guard !result.succeeded else { return }
    Log.network.notice(
      "Could not unmount \(share.name, privacy: .private) again (\(result.timedOut ? "timed out" : "exit \(result.exitCode ?? -1)", privacy: .public)): \(result.stderr, privacy: .private)"
    )
  }

  /// Whether a filesystem is mounted at `path` (device differs from the
  /// parent's). Calls stat(), which can block on a mount whose server is
  /// unresponsive: only use it on paths the mount table shows are not
  /// network mounts.
  private func isMounted(at path: String) -> Bool {
    var fileStat = stat()
    if stat(path, &fileStat) != 0 {
      return false
    }

    var parentStat = stat()
    let parentPath = (path as NSString).deletingLastPathComponent
    if stat(parentPath, &parentStat) != 0 {
      return false
    }

    // If device IDs differ, it's a mount point
    return fileStat.st_dev != parentStat.st_dev
  }

  /// Removes the mount point folder MountMate created for a mount that failed.
  ///
  /// NEVER use FileManager.removeItem here: it is recursive, and if another
  /// mount landed on this path in the meantime (the mount then fails with
  /// "busy"/"file exists"), it deletes the contents of the live network share
  /// (issue #71). The folder is only removed when MountMate created it, the
  /// mount table shows nothing mounted there, and it is not a mount point;
  /// rmdir(2) itself only removes an empty directory and refuses mount points.
  private func cleanUpMountPoint(_ mountPoint: String, ifCreated created: Bool) {
    guard created else { return }
    // If the mount table can't be read, leave the folder alone.
    guard let mountTable = host.currentMountTable(),
      !mountTable.contains(where: { NetworkMountManager.samePath($0.mountPoint, mountPoint) })
    else { return }
    // No network share is mounted there, so stat() on it cannot hang; this
    // also catches non-network filesystems mounted on the folder.
    guard !isMounted(at: mountPoint) else { return }
    _ = rmdir(mountPoint)
  }

  /// Mounts an NFS export with `mount_nfs` (NFS uses no password).
  private func runNFSMount(share: NetworkShare, mountPoint: String) -> MountOutcome {
    // mount_nfs expects the canonical `server:/export` form.
    let exportPath =
      "/"
      + share.sharePath.trimmingCharacters(
        in: CharacterSet(charactersIn: "/"))
    let executable = "/sbin/mount_nfs"
    let result = runProcess(
      executable: executable,
      arguments: ["-o", "resvport", "\(share.server):\(exportPath)", mountPoint])

    if result.succeeded { return .success }
    // runProcess terminates the process on timeout, so no mount can follow.
    if result.timedOut { return .timedOut(mayStillComplete: false) }

    let rawError =
      result.stderr.isEmpty
      ? "\(executable) exited with code \(result.exitCode ?? -1)."
      : result.stderr
    let sanitized = redactingURLPasswords(rawError)
    // Detect permission-related mount failures
    let lower = sanitized.lowercased()
    if lower.contains("permission denied") || lower.contains("operation not permitted")
      || lower.contains("not owner")
    {
      return .failed(
        NetworkMountManager.mountLocationPermissionMessage(share: share, mountPoint: mountPoint))
    }
    return .failed(sanitized)
  }

  /// Mounts an SMB or AFP share through the NetFS framework.
  ///
  /// The password is handed to NetFS directly. It is never part of a
  /// process' arguments (as with `mount_smbfs smb://user:pass@…`), where any
  /// local user could read it with `ps`.
  private func runNetFSMount(
    share: NetworkShare, password: String?, mountPoint: String, userInitiated: Bool
  ) -> MountOutcome {
    let username = share.shareProtocol.supportsUserCredentials ? share.username : ""
    let (urlUser, argumentUser) = Self.netFSUserPlacement(for: share)
    guard let url = Self.connectionURL(for: share, user: urlUser) else {
      return .failed(
        NSLocalizedString("Invalid share configuration", comment: "Network share mount error"))
    }

    // No username: pass no credentials at all, so NetFS uses the Mac's
    // default ones (Kerberos single sign-on, or the login name with a
    // password Finder saved in the Keychain), as mount_smbfs did.
    let credentialPassword = username.isEmpty ? nil : password
    // A late (post-timeout) success of an automatic mount the user ejected
    // meanwhile is undone, as for completions within the timeout.
    let undoIfSuppressed = !userInitiated

    guard
      var status = callNetFS(
        share: share, url: url, mountPoint: mountPoint, user: argumentUser,
        password: credentialPassword, asGuest: false, undoIfSuppressed: undoIfSuppressed)
    else { return .timedOut(mayStillComplete: true) }

    if username.isEmpty, Self.shouldRetryAsGuest(afterStatus: status) {
      Log.network.info(
        "Default credentials for \(share.name, privacy: .private) failed with status \(status, privacy: .public); retrying as guest."
      )
      // The default credentials did not work: try as guest, as the
      // "Optional (Guest)" hint for an empty username promises. Never done
      // when a username is set.
      guard
        let guestStatus = callNetFS(
          share: share, url: url, mountPoint: mountPoint, user: nil, password: nil,
          asGuest: true, undoIfSuppressed: undoIfSuppressed)
      else { return .timedOut(mayStillComplete: true) }
      status = guestStatus
    }

    if status == 0 { return .success }
    if status == ETIMEDOUT { return .timedOut(mayStillComplete: false) }

    if status == EEXIST || status == EBUSY,
      let existing = mountOfSameShare(share, ownMountPoint: mountPoint)
    {
      // Already mounted under another form of the server name (Finder's
      // Bonjour name, an IP address, …). Remember that mount as this share's.
      host.adopt(existing.mountPoint, for: share)
      return .adopted
    }
    Log.network.error(
      "NetFS mount of \(share.name, privacy: .private) failed with status \(status, privacy: .public) (\(NetworkMountManager.netFSStatusName(status) ?? "unknown", privacy: .public))."
    )
    return .failed(
      NetworkMountManager.netFSErrorMessage(status, share: share, mountPoint: mountPoint))
  }

  /// Where the SMB/AFP username goes: (URL user component, `user` argument).
  ///
  /// Domain logins ("DOMAIN;user", or "DOMAIN\user" in Windows notation) go
  /// into the SMB URL's user component (with no password, which is passed
  /// separately): that is where mount_smbfs used to read them, so smbfs
  /// splits domain and user exactly as before; NetFS uses the URL's user name
  /// when the `user` argument is NULL. Every other name, including
  /// "user@domain.com", is passed as the plain `user` argument: in a URL "@"
  /// would be percent-encoded, and whether every NetFS/smbfs path decodes it
  /// again is not documented, so the raw argument is the safe choice.
  static func netFSUserPlacement(for share: NetworkShare) -> (urlUser: String?, user: String?) {
    guard share.shareProtocol.supportsUserCredentials, !share.username.isEmpty else {
      return (nil, nil)
    }
    let username = share.username
    if share.shareProtocol == .smb && (username.contains(";") || username.contains("\\")) {
      return (username.replacingOccurrences(of: "\\", with: ";"), nil)
    }
    return (nil, username)
  }

  /// Whether a mount without a username should be retried as guest after the
  /// default-credentials attempt returned `status`. NetFS reports "needs
  /// credentials" under several codes, so retry on any failure except those
  /// that guest access cannot fix.
  static func shouldRetryAsGuest(afterStatus status: Int32) -> Bool {
    switch status {
    case 0, ETIMEDOUT, ENOENT, EEXIST, EBUSY,
      -5998,  // ENETFSNOSHARESAVAIL
      EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN, ECONNREFUSED:
      return false
    default:
      return true
    }
  }

  /// After NetFS reports the share as already mounted (EEXIST) or our folder
  /// as busy (EBUSY), finds the mount that is this share. At our own folder,
  /// where only MountMate mounts, the same protocol and share path suffice
  /// (the host may be spelled differently). Elsewhere the host must be
  /// equivalent too (case, trailing dot, Bonjour/.local forms, same literal
  /// IP), so another server's "public" share is never linked.
  private func mountOfSameShare(_ share: NetworkShare, ownMountPoint: String)
    -> MountedNetworkShare?
  {
    guard let mountTable = host.currentMountTable() else { return nil }
    if let atOurFolder = mountTable.first(where: {
      NetworkMountManager.samePath($0.mountPoint, ownMountPoint)
        && NetworkMountManager.hasSameSharePath($0, share)
    }) {
      return atOurFolder
    }
    return mountTable.first(where: {
      $0.matches(share) && NetworkMountManager.hasSameSharePath($0, share)
    })
  }

  /// A NetFS call that outlived its timeout and still runs in the background.
  private struct StalledMount {
    let since: Date
    let token: UUID
  }

  /// One `NetFSMountURLSync` call, waiting at most `netFSMountTimeout`.
  /// Returns its status, or nil when it timed out. NetFS calls cannot be
  /// cancelled, so a timed-out call keeps running and the share is marked
  /// stalled until it returns.
  private func callNetFS(
    share: NetworkShare, url: URL, mountPoint: String, user: String?, password: String?,
    asGuest: Bool, undoIfSuppressed: Bool
  ) -> Int32? {
    let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)

    let openOptions = NSMutableDictionary()
    // A menu-bar app must never show NetFS UI (authentication dialogs, share
    // pickers); failures are reported by MountMate instead.
    openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
    if asGuest {
      openOptions[kNetFSUseGuestKey as String] = true
    }

    let mountOptions = NSMutableDictionary()
    // Mount exactly at `mountPoint` instead of in a NetFS-created subfolder.
    mountOptions[kNetFSMountAtMountDirKey as String] = true
    // Share paths may name a folder inside the share ("share/sub").
    mountOptions[kNetFSAllowSubMountsKey as String] = true
    // Same flags the previous `mount_smbfs -o noowners,nosuid` mounts had.
    // MNT_UNKNOWNPERMISSIONS is MNT_IGNORE_OWNERSHIP ("noowners").
    var flags = MNT_NOSUID | MNT_NODEV
    if share.shareProtocol == .smb {
      flags |= MNT_UNKNOWNPERMISSIONS
    }
    mountOptions[kNetFSMountFlagsKey as String] = NSNumber(value: flags)

    final class PendingCall {
      var status: Int32?
      var abandoned = false
      let token = UUID()
    }
    let call = PendingCall()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
      var mountedPaths: Unmanaged<CFArray>?
      let status = NetFSMountURLSync(
        url as CFURL, mountURL as CFURL,
        user.map { $0 as CFString }, password.map { $0 as CFString },
        openOptions as CFMutableDictionary, mountOptions as CFMutableDictionary,
        &mountedPaths)
      mountedPaths?.release()

      self.mountLock.lock()
      call.status = status
      let abandoned = call.abandoned
      // Only clear the stall this call created (a newer attempt may have
      // stalled since).
      if abandoned, self.stalledMounts[share.id]?.token == call.token {
        self.stalledMounts.removeValue(forKey: share.id)
      }
      self.mountLock.unlock()

      if abandoned {
        Log.network.notice(
          "NetFS mount of \(share.name, privacy: .private) finished after timing out (status \(status, privacy: .public))."
        )
        // An automatic mount that landed late although the user ejected the
        // share meanwhile: unmount it again, but only at our own folder.
        if status == 0, undoIfSuppressed,
          KeepAliveManager.shared.isSuppressed(shareID: share.id),
          let mountTable = self.host.currentMountTable(),
          mountTable.contains(where: {
            NetworkMountManager.samePath($0.mountPoint, mountPoint)
              && NetworkMountManager.hasSameSharePath($0, share)
          })
        {
          Log.network.notice(
            "Unmounting \(share.name, privacy: .private) again: it was ejected while the mount was pending."
          )
          self.logUndoUnmount(of: share, at: mountPoint)
        }
        self.host.refreshMountStatus(completion: nil)
      } else {
        semaphore.signal()
      }
    }

    _ = semaphore.wait(timeout: .now() + Self.netFSMountTimeout)

    mountLock.lock()
    let finalStatus = call.status
    if finalStatus == nil {
      call.abandoned = true
      stalledMounts[share.id] = StalledMount(since: Date(), token: call.token)
    }
    mountLock.unlock()
    return finalStatus
  }

  static func timeoutMessage(for share: NetworkShare) -> String {
    String(
      format: NSLocalizedString(
        "Mounting “%@” timed out. Check that the server is reachable and try again.",
        comment: "Network share mount error"),
      share.name)
  }

  /// Builds the protocol-specific connection URL for a share. A password is
  /// never embedded; NetFS receives it separately. `user`, when given, goes
  /// into the URL's (percent-encoded) user component.
  ///
  /// - SMB: `smb://[user@]server/share`
  /// - AFP: `afp://server/share`
  /// - NFS: `nfs://server/export/path`
  static func connectionURL(for share: NetworkShare, user: String? = nil) -> URL? {
    var urlComponents = URLComponents()
    urlComponents.scheme = share.shareProtocol.urlScheme
    urlComponents.user = user
    urlComponents.host = share.server
    urlComponents.path = "/\(share.sharePath)"
    return urlComponents.url
  }
}
