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

/// Mounts saved network shares (SMB/AFP through NetFS, NFS through
/// `mount_nfs`) and tracks in-flight and stalled mount attempts. The pure
/// decisions (may this attempt start, how a result is reported, how the NetFS
/// connection is shaped) live in `NetworkMountPlan`; this type is the I/O
/// around them.
final class NetworkShareMounter {
  private unowned let host: NetworkShareMounterHost

  /// Completions waiting on an in-flight mount, keyed by share ID. Login
  /// auto-mount, keep-alive sweeps (launch, wake, network change) and manual
  /// clicks can all ask for the same share at once; only one mount_* process
  /// may run per share, the rest piggyback on its result.
  private var pendingMountCompletions: [UUID: [(Bool, String?) -> Void]] = [:]
  /// Shares whose NetFS mount call outlived `NetworkMountPlan
  /// .stalledMountRetryAge` and is still running in the background (NetFS
  /// calls cannot be cancelled). New attempts for such a share fail fast
  /// instead of stacking a second mount onto the same folder. Guarded by
  /// `mountLock`.
  private var stalledMounts: [UUID: NetworkMountPlan.StalledMount] = [:]
  private let mountLock = NSLock()

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
    let stallAge = mountLock.withLock { stalledMounts[share.id] }
      .map { Date().timeIntervalSince($0.since) }

    // Decide "already mounted" from the kernel mount table only. stat() and
    // other file checks on a mount point whose server stopped responding can
    // block indefinitely (which used to wedge keep-alive sweeps).
    let mountTable = host.currentMountTable()
    let existingMount = mountTable.flatMap { host.mounts(of: share, in: $0).first }

    switch NetworkMountPlan.preflight(
      share: share, mountPoint: mountPoint, userInitiated: userInitiated,
      stallAge: stallAge, mountTable: mountTable, existingMount: existingMount)
    {
    case .blocked(let message):
      finish(false, message)
      return
    case .alreadyMounted:
      Log.network.info(
        "Share \(share.name, privacy: .private) is already mounted at \(existingMount?.mountPoint ?? "", privacy: .private)"
      )
      host.refreshMountStatus(completion: nil)
      finish(true, nil)
      return
    case .proceed:
      break
    }
    if let stallAge {
      Log.network.notice(
        "Retrying \(share.name, privacy: .private) although an earlier NetFS call is stalled (\(Int(stallAge), privacy: .public)s)."
      )
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
      finish(
        false,
        NetworkMountPlan.mountPointCreationFailureMessage(
          error: error, mountPoint: mountPoint, shareName: share.name))
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
        finish(false, NetworkMountPlan.keychainFailureMessage(for: share, status: status))
        return
      }
      outcome = runNetFSMount(
        share: share, password: password, mountPoint: mountPoint, userInitiated: userInitiated)
    }

    let isSuppressed = KeepAliveManager.shared.isSuppressed(shareID: share.id)
    let resolution = NetworkMountPlan.resolution(
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
  /// The decision is `MountPointCleanupRule.shouldRemove`.
  private func cleanUpMountPoint(_ mountPoint: String, ifCreated created: Bool) {
    guard created else { return }
    // If the mount table can't be read, leave the folder alone.
    let mountTable = host.currentMountTable()
    // isMounted(at:) only runs when no network share is mounted there, so
    // stat() on it cannot hang; it also catches non-network filesystems
    // mounted on the folder.
    guard
      MountPointCleanupRule.shouldRemove(
        created: created,
        tableReadable: mountTable != nil,
        inMountTable: mountTable?.contains(where: {
          NetworkMountTable.samePath($0.mountPoint, mountPoint)
        }) ?? false,
        isMountPoint: isMounted(at: mountPoint))
    else { return }
    _ = rmdir(mountPoint)
  }

  /// Mounts an NFS export with `mount_nfs` (NFS uses no password).
  private func runNFSMount(share: NetworkShare, mountPoint: String) -> MountOutcome {
    let executable = "/sbin/mount_nfs"
    let result = runProcess(
      executable: executable,
      arguments: NetworkMountPlan.nfsArguments(share: share, mountPoint: mountPoint))

    if result.succeeded { return .success }
    // runProcess terminates the process on timeout, so no mount can follow.
    if result.timedOut { return .timedOut(mayStillComplete: false) }
    return .failed(
      NetworkMountPlan.nfsFailureMessage(
        stderr: result.stderr, executable: executable, exitCode: result.exitCode,
        share: share, mountPoint: mountPoint))
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
    let (urlUser, argumentUser) = NetworkMountPlan.netFSUserPlacement(for: share)
    guard let url = NetworkMountPlan.connectionURL(for: share, user: urlUser) else {
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

    if username.isEmpty, NetworkMountPlan.shouldRetryAsGuest(afterStatus: status) {
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
      let existing = NetworkMountPlan.mountOfSameShare(
        share, ownMountPoint: mountPoint, mountTable: host.currentMountTable())
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

  /// One `NetFSMountURLSync` call, waiting at most `NetworkMountPlan
  /// .netFSMountTimeout`. Returns its status, or nil when it timed out. NetFS
  /// calls cannot be cancelled, so a timed-out call keeps running and the
  /// share is marked stalled until it returns.
  private func callNetFS(
    share: NetworkShare, url: URL, mountPoint: String, user: String?, password: String?,
    asGuest: Bool, undoIfSuppressed: Bool
  ) -> Int32? {
    let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
    let openOptions = NetworkMountPlan.netFSOpenOptions(asGuest: asGuest)
    let mountOptions = NetworkMountPlan.netFSMountOptions(for: share)

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
            NetworkMountTable.samePath($0.mountPoint, mountPoint)
              && NetworkMountTable.hasSameSharePath($0, share)
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

    _ = semaphore.wait(timeout: .now() + NetworkMountPlan.netFSMountTimeout)

    mountLock.lock()
    let finalStatus = call.status
    if finalStatus == nil {
      call.abandoned = true
      stalledMounts[share.id] = NetworkMountPlan.StalledMount(since: Date(), token: call.token)
    }
    mountLock.unlock()
    return finalStatus
  }
}
