//  Created by homielab.com

import Foundation
import NetFS

/// What the protocol-specific mount step reported.
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

/// Whether a mount attempt may start and how its result is reported. Pure
/// decisions around mounting a saved network share — no I/O — so every branch
/// is unit-tested (`NetworkMountPlanTests`). The I/O lives in
/// `NetworkShareMounter`.
enum NetworkMountPlan {
  /// After this long, a user-initiated mount may start even though an
  /// earlier NetFS call for the share never returned (it may never). Keep-
  /// alive keeps waiting, so automatic mounts never run concurrently.
  static let stalledMountRetryAge: TimeInterval = 150

  /// Whether a mount attempt must fail fast because an earlier NetFS call for
  /// the share has been stalled for `stallAge` seconds. Automatic mounts
  /// always wait; the user may retry once the stall is old enough.
  static func shouldBlock(stallAge: TimeInterval, userInitiated: Bool) -> Bool {
    !(userInitiated && stallAge >= stalledMountRetryAge)
  }

  /// How a failed `umount` is reported and whether `umount -f` is worth
  /// offering (the user still has to confirm it).
  struct UnmountFailure: Equatable {
    let message: String
    let canForce: Bool
  }

  /// Turns a failed `umount` into a translated message. Busy shares, timeouts
  /// and unknown errors can be forced; a share that is not mounted any more
  /// cannot. `localize` is injectable so tests do not depend on the system
  /// language.
  static func unmountFailure(
    for result: ProcessResult,
    shareName: String,
    localize: (String) -> String = { NSLocalizedString($0, comment: "Network share unmount error") }
  ) -> UnmountFailure {
    if result.timedOut {
      return UnmountFailure(
        message: String(format: localize("Unmounting “%@” timed out."), shareName), canForce: true)
    }
    let stderr = result.stderr.lowercased()
    if stderr.contains("not currently mounted") || stderr.contains("not a mount point")
      || stderr.contains("not mounted")
    {
      return UnmountFailure(
        message: String(format: localize("“%@” is no longer mounted."), shareName),
        canForce: false)
    }
    if stderr.contains("busy") {
      return UnmountFailure(
        message: String(
          format: localize("“%@” is busy: a file on it is still in use."), shareName),
        canForce: true)
    }
    if result.stderr.isEmpty {
      return UnmountFailure(
        message: String(
          format: localize("Could not unmount “%@” (code %d)."), shareName,
          Int(result.exitCode ?? -1)),
        canForce: true)
    }
    return UnmountFailure(
      message: String(
        format: localize("Could not unmount “%@”: %@"), shareName, result.stderr),
      canForce: true)
  }

  /// NetFS has no timeout of its own and can block for a long time on an
  /// unreachable server. The mount is abandoned (reported as timed out)
  /// after this long so the UI and keep-alive sweeps never get stuck.
  static let netFSMountTimeout: TimeInterval = 30

  /// A NetFS call that outlived its timeout and still runs in the background.
  struct StalledMount: Equatable {
    let since: Date
    let token: UUID
  }

  /// Why a mount attempt cannot proceed. `stallAge` is the age of an earlier
  /// NetFS call that never returned (nil when none is stalled),
  /// `existingMount` the share's own mount found in the kernel mount table.
  enum Preflight: Equatable {
    case proceed
    case alreadyMounted
    case blocked(message: String)
  }

  /// The checks `NetworkShareMounter` runs before starting a protocol mount:
  /// a stalled earlier call, the share already mounted, and the target folder
  /// occupied by a different share (never mounted on top of).
  static func preflight(
    share: NetworkShare, mountPoint: String, userInitiated: Bool,
    stallAge: TimeInterval?, mountTable: [MountedNetworkShare]?,
    existingMount: MountedNetworkShare?
  ) -> Preflight {
    if let stallAge {
      guard !shouldBlock(stallAge: stallAge, userInitiated: userInitiated) else {
        return .blocked(
          message: String(
            format: NSLocalizedString(
              "A previous connection attempt to “%@” is still in progress.",
              comment: "Network share mount error"),
            share.name))
      }
    }
    if existingMount != nil { return .alreadyMounted }
    // Our target folder may be occupied by a DIFFERENT share (e.g. two saved
    // shares with the same name). Never report that as success, and never
    // mount on top of it.
    if let occupant = mountTable?.first(where: {
      NetworkMountTable.samePath($0.mountPoint, mountPoint)
    }) {
      return .blocked(
        message: String(
          format: NSLocalizedString(
            "“%@” cannot be mounted at “%@” because another share (%@) is already mounted there.",
            comment: "Network share mount error: mount point used by another share"),
          share.name, mountPoint, redactingURLPasswords(occupant.source)))
    }
    return .proceed
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

  static func timeoutMessage(for share: NetworkShare) -> String {
    let base = String(
      format: NSLocalizedString(
        "Mounting “%@” timed out. Check that the server is reachable and try again.",
        comment: "Network share mount error"),
      share.name)
    if share.shareProtocol.isDeprecated {
      let hint = NSLocalizedString(
        "Apple has removed support for AFP in modern macOS versions. Consider switching this share to SMB or NFS.",
        comment: "Deprecated share protocol hint")
      return "\(base)\n\n\(hint)"
    }
    return base
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
    // `admin@nas:445` or `[fe80::1]` in the server field: the host alone
    // goes in `host` (IPv6 in brackets, or the URL is nil), the port apart.
    let address = NetworkShare.hostAndPort(fromServer: share.server)
    urlComponents.host = address.host.contains(":") ? "[\(address.host)]" : address.host
    urlComponents.port = address.port
    urlComponents.path = "/\(share.sharePath)"
    return urlComponents.url
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

  /// The user-readable failure for a Keychain read that failed: MountMate
  /// never falls back to an empty password, which would turn a Keychain
  /// problem into a confusing authentication failure (or a guest connection).
  static func keychainFailureMessage(for share: NetworkShare, status: Int32) -> String {
    String(
      format: NSLocalizedString(
        "MountMate could not read the saved password for “%@” from the Keychain (error %d).",
        comment: "Network share mount error: keychain read failed"),
      share.name, status)
  }

  /// The `mount_nfs` arguments for a share: the canonical `server:/export`
  /// form on `resvport`.
  static func nfsArguments(share: NetworkShare, mountPoint: String) -> [String] {
    let exportPath =
      "/"
      + share.sharePath.trimmingCharacters(
        in: CharacterSet(charactersIn: "/"))
    return ["-o", "resvport", "\(share.server):\(exportPath)", mountPoint]
  }

  /// After NetFS reports the share as already mounted (EEXIST) or our folder
  /// as busy (EBUSY), finds the mount that is this share. At our own folder,
  /// where only MountMate mounts, the same protocol and share path suffice
  /// (the host may be spelled differently). Elsewhere the host must be
  /// equivalent too (case, trailing dot, Bonjour/.local forms, same literal
  /// IP), so another server's "public" share is never linked.
  static func mountOfSameShare(
    _ share: NetworkShare, ownMountPoint: String, mountTable: [MountedNetworkShare]?
  ) -> MountedNetworkShare? {
    guard let mountTable else { return nil }
    if let atOurFolder = mountTable.first(where: {
      NetworkMountTable.samePath($0.mountPoint, ownMountPoint)
        && NetworkMountTable.hasSameSharePath($0, share)
    }) {
      return atOurFolder
    }
    return mountTable.first(where: {
      $0.matches(share) && NetworkMountTable.hasSameSharePath($0, share)
    })
  }

  /// The user-readable failure for an NFS `mount_nfs` run: the sanitized
  /// stderr (or the bare exit code), with permission failures getting the
  /// mount-location guidance.
  static func nfsFailureMessage(
    stderr: String, executable: String, exitCode: Int32?,
    share: NetworkShare, mountPoint: String
  ) -> String {
    let rawError =
      stderr.isEmpty
      ? "\(executable) exited with code \(exitCode ?? -1)."
      : stderr
    let sanitized = redactingURLPasswords(rawError)
    // Detect permission-related mount failures
    let lower = sanitized.lowercased()
    if lower.contains("permission denied") || lower.contains("operation not permitted")
      || lower.contains("not owner")
    {
      return NetworkMountManager.mountLocationPermissionMessage(
        share: share, mountPoint: mountPoint)
    }
    return sanitized
  }

  /// The user-readable failure for the mount point folder that could not be
  /// created: administrator guidance where the location demands privileges
  /// (or the path is gone), the system error otherwise.
  static func mountPointCreationFailureMessage(
    error: Error, mountPoint: String, shareName: String
  ) -> String {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain
      && (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileNoSuchFileError)
    {
      return String(
        format: NSLocalizedString(
          "Cannot create mount point at “%1$@”.\n\nThis location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/%2$@) or leave the Custom Mount Point empty to use the default location.",
          comment: "Network share mount error: 1 = mount point path, 2 = share name"),
        mountPoint, shareName)
    }
    return String(
      format: NSLocalizedString(
        "Failed to create mount point at “%1$@”: %2$@",
        comment: "Network share mount error: 1 = mount point path, 2 = system error"),
      mountPoint, error.localizedDescription)
  }

  /// The NetFS open options: never any NetFS UI (a menu-bar app must not pop
  /// authentication dialogs or share pickers; MountMate reports failures
  /// itself), guest access when asked.
  static func netFSOpenOptions(asGuest: Bool) -> NSMutableDictionary {
    let openOptions = NSMutableDictionary()
    openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
    if asGuest {
      openOptions[kNetFSUseGuestKey as String] = true
    }
    return openOptions
  }

  /// The NetFS mount options: mount exactly at the requested folder instead
  /// of a NetFS-created subfolder, allow share paths that name a folder
  /// inside the share ("share/sub"), and the same flags the previous
  /// `mount_smbfs -o noowners,nosuid` mounts had (MNT_UNKNOWNPERMISSIONS is
  /// MNT_IGNORE_OWNERSHIP, "noowners").
  static func netFSMountOptions(for share: NetworkShare) -> NSMutableDictionary {
    let mountOptions = NSMutableDictionary()
    mountOptions[kNetFSMountAtMountDirKey as String] = true
    mountOptions[kNetFSAllowSubMountsKey as String] = true
    var flags = MNT_NOSUID | MNT_NODEV
    if share.shareProtocol == .smb {
      flags |= MNT_UNKNOWNPERMISSIONS
    }
    mountOptions[kNetFSMountFlagsKey as String] = NSNumber(value: flags)
    return mountOptions
  }
}
