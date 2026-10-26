//  Created by homielab.com

import AppKit
import Foundation
import NetFS

struct ShareUsage: Equatable {
  let totalBytes: Int64
  let freeBytes: Int64

  var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
  var percentage: Double { min(1, Double(usedBytes) / Double(totalBytes)) }
}

class NetworkMountManager: ObservableObject {
  static let shared = NetworkMountManager()

  @Published var mountedShareIDs: Set<UUID> = []
  /// Where each saved (and manually connected) share is currently mounted,
  /// from the last status refresh. Main thread only.
  private(set) var mountPointsByShareID: [UUID: String] = [:]
  /// Total and free bytes of each mounted share, from the last status refresh.
  @Published private(set) var usageByShareID: [UUID: ShareUsage] = [:]
  @Published var manuallyConnectedShares: [NetworkShare] = []
  @Published var isUnmountingManualShares = false

  private var manualSharesDictionary: [String: NetworkShare] = [:]

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
  private static let stalledMountRetryAge: TimeInterval = 150

  /// Guards `manualSharesDictionary`, `adoptions` and `savedSharesSnapshot`,
  /// which status refreshes on background threads read and write.
  private let parseLock = NSLock()
  /// Mounts accepted as a saved share's although their host is spelled
  /// differently (e.g. Finder's "NAS._smb._tcp.local" or an IP address),
  /// keyed by share ID. Recorded when NetFS reports the share as already
  /// mounted; dropped when the mount disappears, the share's endpoint
  /// changes, or the share is removed (see `attributeMounts`).
  private var adoptions: [UUID: Adoption] = [:]
  /// Saved shares as of the last status refresh (for attribution off main).
  private var savedSharesSnapshot: [NetworkShare] = []

  /// NetFS has no timeout of its own and can block for a long time on an
  /// unreachable server. The mount is abandoned (reported as timed out)
  /// after this long so the UI and keep-alive sweeps never get stuck.
  private static let netFSMountTimeout: TimeInterval = 30

  private var workspaceObservers: [NSObjectProtocol] = []
  private var mountEventDebounce: DispatchWorkItem?
  /// `refreshMountStatus` runs overlap (keep-alive, mount events, Eject
  /// All); these keep a slow older run from overwriting a newer result.
  /// Main thread only.
  private var mountStatusGate = LatestResultGate()
  private var shareUsageGate = LatestResultGate()

  private init() {
    // Initial check
    refreshMountStatus()

    // Refresh share status on mount/unmount events (debounced so a burst of
    // events reads the mount table once), instead of on every disk refresh.
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          self?.scheduleMountEventRefresh()
        })
    }
  }

  private func scheduleMountEventRefresh() {
    mountEventDebounce?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refreshMountStatus() }
    mountEventDebounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
  }

  func refreshMountStatus(completion: (() -> Void)? = nil) {
    // Snapshot the saved shares on the main thread (PersistenceManager is
    // main-thread state); this may be called from any thread.
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        completion?()
        return
      }
      let savedShares = PersistenceManager.shared.networkShares
      let ticket = self.mountStatusGate.begin()
      DispatchQueue.global(qos: .userInitiated).async {
        self.refreshMountStatus(savedShares: savedShares, ticket: ticket, completion: completion)
      }
    }
  }

  /// Background part of `refreshMountStatus(completion:)`. `ticket` comes
  /// from `mountStatusGate`: a result older than the one already shown is
  /// dropped (its completion still runs; the newer state is in place).
  private func refreshMountStatus(
    savedShares: [NetworkShare], ticket: Int, completion: (() -> Void)?
  ) {
    guard let mountedShares = MountTable.networkShares() else {
      Log.network.error("Could not read the mount table (getfsstat failed).")
      DispatchQueue.main.async { completion?() }
      return
    }
    Log.network.debug(
      "Mount table: \(mountedShares.count, privacy: .public) network share(s).")

    let parsedData = self.parseMountedShares(mountedShares, savedShares: savedShares)

    DispatchQueue.main.async {
      guard self.mountStatusGate.shouldApply(ticket) else {
        completion?()
        return
      }
      // Assigning an @Published property re-renders every observing view
      // even when the value is identical, and this runs on every
      // keep-alive tick: only publish actual changes.
      if self.mountedShareIDs != parsedData.mountedUUIDs {
        self.mountedShareIDs = parsedData.mountedUUIDs
      }
      self.mountPointsByShareID = parsedData.mountPoints
      if self.manuallyConnectedShares != parsedData.manualShares {
        self.manuallyConnectedShares = parsedData.manualShares
      }
      completion?()
    }

    // Usage is read after completion so a slow server never delays mounts or
    // keep-alive sweeps. statfs each share in parallel: an unreachable server
    // costs one timeout, not one per share.
    let mounts = Array(parsedData.mountPoints)
    var results = [DriveManager.FileSystemUsageResult?](repeating: nil, count: mounts.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: mounts.count) { index in
      let result = DriveManager.fileSystemUsage(atPath: mounts[index].value)
      lock.withLock { results[index] = result }
    }

    DispatchQueue.main.async {
      guard self.shareUsageGate.shouldApply(ticket) else { return }
      var usage = [UUID: ShareUsage]()
      for (index, mount) in mounts.enumerated() {
        switch results[index] {
        case .usage(let total, let free) where total > 0:
          usage[mount.key] = ShareUsage(totalBytes: total, freeBytes: free)
        case .timedOut:
          // Keep the last known value while the server is slow to answer.
          usage[mount.key] = self.usageByShareID[mount.key]
        default:
          break
        }
      }
      if self.usageByShareID != usage {
        self.usageByShareID = usage
      }
    }
  }

  /// Returns the currently mounted network shares that are not already saved in
  /// MountMate. Refreshing first keeps the result useful when Settings has been
  /// open for a while.
  func discoverManuallyMountedShares(completion: @escaping ([NetworkShare]) -> Void) {
    refreshMountStatus { [weak self] in
      completion(self?.manuallyConnectedShares ?? [])
    }
  }

  /// Resolves a Finder URL dropped anywhere inside a mounted share back to its
  /// network share.
  func manuallyMountedShare(containing url: URL) -> NetworkShare? {
    let droppedPath = url.standardizedFileURL.path
    return manuallyConnectedShares.first { share in
      guard let mountPoint = mountPointsByShareID[share.id] else { return false }
      let mountedPath = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
      return droppedPath == mountedPath || droppedPath.hasPrefix(mountedPath + "/")
    }
  }

  private func parseMountedShares(
    _ mountedShares: [MountedNetworkShare], savedShares shares: [NetworkShare]
  ) -> (mountedUUIDs: Set<UUID>, manualShares: [NetworkShare], mountPoints: [UUID: String]) {
    // Refreshes can run concurrently on background threads.
    parseLock.lock()
    defer { parseLock.unlock() }

    var mountedUUIDs = Set<UUID>()
    var mountPoints = [UUID: String]()
    var currentManualShareMountPoints = Set<String>()
    var manualShares = [NetworkShare]()

    // Which saved share each mount is; also drops stale adoptions.
    let attribution = Self.attributeMounts(mountedShares, to: shares, adoptions: adoptions)
    adoptions = attribution.adoptions
    savedSharesSnapshot = shares

    for (index, mountedShare) in mountedShares.enumerated() {
      if let ownerID = attribution.owners[index],
        let savedShare = shares.first(where: { $0.id == ownerID })
      {
        mountedUUIDs.insert(savedShare.id)
        if mountPoints[savedShare.id] == nil {
          mountPoints[savedShare.id] = mountedShare.mountPoint
        }
        continue
      }
      // A share connected outside MountMate (Finder, Terminal…). Keep the
      // same NetworkShare (and ID) while it stays mounted at this path.
      currentManualShareMountPoints.insert(mountedShare.mountPoint)
      let manualShare =
        manualSharesDictionary[mountedShare.mountPoint] ?? Self.importedShare(from: mountedShare)
      manualSharesDictionary[mountedShare.mountPoint] = manualShare
      manualShares.append(manualShare)
      mountPoints[manualShare.id] = mountedShare.mountPoint
    }

    // Clean up old manual shares that are no longer mounted
    manualSharesDictionary = manualSharesDictionary.filter {
      currentManualShareMountPoints.contains($0.key)
    }

    return (mountedUUIDs, manualShares, mountPoints)
  }

  /// The share MountMate offers to import for a mount it did not make:
  /// server, share path and user from the mount source (`server:/export`
  /// for NFS, `//[user@]server/share` for SMB and AFP), named after the last
  /// path component. When the source cannot be read, the server is
  /// "Unknown Server" and the share path the mount folder's name (or
  /// "Shared Folder"). `localize` is replaceable so tests are independent of
  /// the system language.
  static func importedShare(
    from mountedShare: MountedNetworkShare,
    localize: (String) -> String = { NSLocalizedString($0, comment: "Imported network share") }
  ) -> NetworkShare {
    var username = ""
    var server = ""
    var sharePath = ""

    switch mountedShare.shareProtocol {
    case .nfs:
      // NFS sources look like `server:/export/path` or `[v6addr]:/export`.
      var rest = Substring(mountedShare.source)
      if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
        server = String(rest[rest.index(after: rest.startIndex)..<close])
        rest = rest[rest.index(after: close)...]
      } else if let colon = rest.firstIndex(of: ":") {
        server = String(rest[..<colon])
        rest = rest[colon...]
      } else {
        server = String(rest)
        rest = ""
      }
      if rest.hasPrefix(":") { rest = rest.dropFirst() }
      sharePath = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    case .smb, .afp:
      let urlString = mountedShare.source.replacingOccurrences(
        of: "//", with: "\(mountedShare.shareProtocol.urlScheme)://")
      if let url = URL(string: urlString) {
        username = url.user ?? ""
        server = url.host ?? ""
        sharePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      }
    }

    if server.isEmpty {
      server = localize("Unknown Server")
    }
    if sharePath.isEmpty {
      let folder = (mountedShare.mountPoint as NSString).lastPathComponent
      sharePath = folder.isEmpty || folder == "/" ? localize("Shared Folder") : folder
    }

    // The last path component, so the name (the default mount folder if
    // imported) never contains "/" ("volume1/data" → "data").
    let name = sharePath.split(separator: "/").last.map(String.init) ?? sharePath
    return NetworkShare(
      name: name,
      server: server,
      sharePath: sharePath,
      username: username,
      mountAtLogin: false,
      keepMounted: false,
      shareProtocol: mountedShare.shareProtocol,
      // Not the current mount path: if this share is imported, its later
      // mounts must use MountMate's default user-owned location (e.g. not
      // /Volumes/public, which needs admin rights). The current location is
      // tracked in `mountPointsByShareID`.
      customMountPoint: nil
    )
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
  private enum MountOutcome {
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
    let mountPoint = configuredMountPoint(for: share)

    // An earlier NetFS call for this share timed out and is still running.
    // Automatic mounts always wait for it (no concurrent mounts onto the
    // same folder); the user may retry once it is old enough, since a call
    // that never returns would otherwise block the share all session.
    if let stall = mountLock.withLock({ stalledMounts[share.id] }) {
      let age = Date().timeIntervalSince(stall.since)
      guard userInitiated, age >= Self.stalledMountRetryAge else {
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
    let mountTable = currentMountTable()

    // Already mounted (at our target path or elsewhere)?
    if let existingMount = mountTable.flatMap({ mounts(of: share, in: $0).first }) {
      Log.network.info(
        "Share \(share.name, privacy: .private) is already mounted at \(existingMount.mountPoint, privacy: .private)"
      )
      refreshMountStatus()
      finish(true, nil)
      return
    }

    // Our target folder may be occupied by a DIFFERENT share (e.g. two saved
    // shares with the same name). Never report that as success, and never
    // mount on top of it.
    if let occupant = mountTable?.first(where: { Self.samePath($0.mountPoint, mountPoint) }) {
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

    switch outcome {
    case .success:
      if !userInitiated && KeepAliveManager.shared.isSuppressed(shareID: share.id) {
        // The user ejected this share in MountMate while this automatic
        // mount was in flight: undo it.
        Log.network.notice(
          "Unmounting \(share.name, privacy: .private) again: it was ejected during an automatic mount."
        )
        logUndoUnmount(of: share, at: mountPoint)
        cleanUpMountPoint(mountPoint, ifCreated: createdMountPoint)
        refreshMountStatus { finish(false, nil) }
      } else {
        refreshMountStatus { finish(true, nil) }
      }
    case .adopted:
      cleanUpMountPoint(mountPoint, ifCreated: createdMountPoint)
      refreshMountStatus { finish(true, nil) }
    case .timedOut(let mayStillComplete):
      if !mayStillComplete {
        cleanUpMountPoint(mountPoint, ifCreated: createdMountPoint)
      }
      refreshMountStatus { finish(false, self.timeoutMessage(for: share)) }
    case .failed(let message):
      cleanUpMountPoint(mountPoint, ifCreated: createdMountPoint)
      refreshMountStatus { finish(false, message) }
    }
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
    guard let mountTable = currentMountTable(),
      !mountTable.contains(where: { Self.samePath($0.mountPoint, mountPoint) })
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
      return .failed(Self.mountLocationPermissionMessage(share: share, mountPoint: mountPoint))
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
    guard let url = connectionURL(for: share, user: urlUser) else {
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
      adopt(existing.mountPoint, for: share)
      return .adopted
    }
    Log.network.error(
      "NetFS mount of \(share.name, privacy: .private) failed with status \(status, privacy: .public) (\(Self.netFSStatusName(status) ?? "unknown", privacy: .public))."
    )
    return .failed(Self.netFSErrorMessage(status, share: share, mountPoint: mountPoint))
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
    guard let mountTable = currentMountTable() else { return nil }
    if let atOurFolder = mountTable.first(where: {
      Self.samePath($0.mountPoint, ownMountPoint) && Self.hasSameSharePath($0, share)
    }) {
      return atOurFolder
    }
    return mountTable.first(where: { $0.matches(share) && Self.hasSameSharePath($0, share) })
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
          let mountTable = self.currentMountTable(),
          mountTable.contains(where: {
            Self.samePath($0.mountPoint, mountPoint) && Self.hasSameSharePath($0, share)
          })
        {
          Log.network.notice(
            "Unmounting \(share.name, privacy: .private) again: it was ejected while the mount was pending."
          )
          self.logUndoUnmount(of: share, at: mountPoint)
        }
        self.refreshMountStatus()
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

  private func timeoutMessage(for share: NetworkShare) -> String {
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
  func connectionURL(for share: NetworkShare, user: String? = nil) -> URL? {
    var urlComponents = URLComponents()
    urlComponents.scheme = share.shareProtocol.urlScheme
    urlComponents.user = user
    urlComponents.host = share.server
    urlComponents.path = "/\(share.sharePath)"
    return urlComponents.url
  }

  func mountAllAutoShares() {
    let shares = PersistenceManager.shared.networkShares.filter { $0.mountAtLogin }
    for share in shares {
      // Automatic: must not clear keep-alive suppression or backoff state.
      mount(share: share, userInitiated: false) { success, error in
        if !success {
          // Error is already sanitized by mount()
          Log.network.error(
            "Failed to auto-mount \(share.name, privacy: .private): \(error ?? "Unknown error", privacy: .private)"
          )
        } else {
          Log.network.notice("Auto-mounted \(share.name, privacy: .private)")
        }
      }
    }
  }

  /// Unmounts and immediately mounts a share again so the connection is
  /// re-established over the current network path. Used after network
  /// interface changes when the stale mount still exists. `completion`
  /// receives whether the share ended up mounted.
  func forceRemount(share: NetworkShare, completion: ((Bool) -> Void)? = nil) {
    let lastKnownMountPoint = mountPointsByShareID[share.id]
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      // Unmount where the share really is, never just the configured path:
      // that folder may hold a different share with the same name.
      if let mountPoint = self.liveMountPoint(for: share, lastKnown: lastKnownMountPoint) {
        // Only remount mounts MountMate made (at the share's own folder).
        // A mount elsewhere, e.g. the user's own Finder mount in /Volumes,
        // is left alone: it is mounted, which is all keep-alive needs.
        guard Self.samePath(mountPoint, self.configuredMountPoint(for: share)) else {
          DispatchQueue.main.async { completion?(true) }
          return
        }
        let umountResult = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
        if !umountResult.succeeded {
          Log.network.notice(
            "Unmount before remounting \(share.name, privacy: .private) failed (\(umountResult.timedOut ? "timed out" : "exit \(umountResult.exitCode ?? -1)", privacy: .public)): \(umountResult.stderr, privacy: .private)"
          )
          let stillMounted =
            self.currentMountTable().map { !self.mounts(of: share, in: $0).isEmpty } ?? true
          if !Self.shouldRemount(afterUnmountSucceeded: false, stillMounted: stillMounted) {
            // Busy share: it is still mounted, so there is nothing to
            // reconnect and a second mount would only fail.
            DispatchQueue.main.async { completion?(true) }
            return
          }
        }
      }
      DispatchQueue.main.async {
        // Automatic: must not clear keep-alive suppression or backoff state.
        self.mount(share: share, userInitiated: false) { success, _ in
          completion?(success)
        }
      }
    }
  }

  /// Whether `forceRemount` should mount again: always after a successful
  /// unmount, and after a failed one only when the share is gone anyway.
  static func shouldRemount(afterUnmountSucceeded: Bool, stillMounted: Bool) -> Bool {
    afterUnmountSucceeded || !stillMounted
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

  /// Marks a share as intentionally unmounted by the user so the keep-alive
  /// layer does not fight that decision. Cleared on the next explicit mount.
  func markShareUnmountedByUser(_ share: NetworkShare) {
    KeepAliveManager.shared.suppress(shareID: share.id)
  }

  func unmount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    let lastKnownMountPoint = mountPointsByShareID[share.id]

    // Suppress keep-alive BEFORE unmounting: otherwise a sweep running in the
    // window between umount finishing and the suppression could remount the
    // share the user just ejected. Undone below if the unmount fails.
    let wasSuppressed = KeepAliveManager.shared.isSuppressed(shareID: share.id)
    markShareUnmountedByUser(share)

    DispatchQueue.global(qos: .userInitiated).async {
      // Unmount where the share really is (from a fresh mount table), never
      // just the configured path: that folder may hold a different share.
      guard let mountPoint = self.liveMountPoint(for: share, lastKnown: lastKnownMountPoint)
      else {
        // Not mounted any more (e.g. ejected in Finder): nothing to do.
        DispatchQueue.main.async {
          self.refreshMountStatus { completion(true, nil) }
        }
        return
      }

      let result = runProcess(executable: "/sbin/umount", arguments: [mountPoint])

      DispatchQueue.main.async {
        if !result.succeeded {
          if !wasSuppressed {
            KeepAliveManager.shared.unsuppress(shareID: share.id)
          }
          let errMsg: String
          if result.timedOut {
            errMsg = String(
              format: NSLocalizedString(
                "Unmounting “%@” timed out.", comment: "Network share unmount error"),
              share.name)
          } else if result.stderr.isEmpty {
            errMsg = "umount exited with code \(result.exitCode ?? -1)."
          } else {
            errMsg = result.stderr
          }
          self.refreshMountStatus {
            completion(false, errMsg)
          }
        } else {
          self.refreshMountStatus {
            completion(true, nil)
          }
        }
      }
    }
  }

  func unmountAllManuallyConnectedShares(completion: @escaping ([String]) -> Void) {
    let shares = manuallyConnectedShares
    guard !shares.isEmpty else {
      completion([])
      return
    }

    // Manually connected shares are unmounted where the mount table says they
    // are (read on the main thread, before going to the background). No
    // fallback to a configured path: that could hit a saved share's folder.
    let targets = shares.compactMap { share -> (name: String, mountPoint: String)? in
      guard let mountPoint = mountPointsByShareID[share.id] else { return nil }
      return (name: share.name, mountPoint: mountPoint)
    }

    isUnmountingManualShares = true
    DispatchQueue.global(qos: .userInitiated).async {
      let failures = targets.compactMap { target -> String? in
        let result = runProcess(executable: "/sbin/umount", arguments: [target.mountPoint])
        return !result.succeeded ? target.name : nil
      }

      DispatchQueue.main.async {
        self.isUnmountingManualShares = false
        self.refreshMountStatus()
        completion(failures)
      }
    }
  }

  func isMounted(share: NetworkShare) -> Bool {
    return mountedShareIDs.contains(share.id)
  }

  /// Where the share is (or will be) mounted. Uses the cached mount table from
  /// the last status refresh so it is safe to call from UI code.
  func getMountPoint(for share: NetworkShare) -> String {
    if let mountedPath = mountPointsByShareID[share.id] {
      return mountedPath
    }

    return configuredMountPoint(for: share)
  }

  /// Where MountMate mounts the share: its custom mount point, or
  /// `~/mountmate/<name>`. Also used by the share editor to detect two saved
  /// shares that would use the same folder.
  func configuredMountPoint(for share: NetworkShare) -> String {
    Self.configuredMountPoint(
      for: share, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
  }

  /// `configuredMountPoint(for:)` with the home folder passed in: a relative
  /// custom path is taken from `homeDirectory`.
  static func configuredMountPoint(for share: NetworkShare, homeDirectory homeDir: String)
    -> String
  {
    if let customPath = share.customMountPoint, !customPath.isEmpty {
      let expandedPath = (customPath as NSString).expandingTildeInPath
      if !expandedPath.hasPrefix("/") {
        return "\(homeDir)/\(expandedPath)"
      } else {
        return expandedPath
      }
    } else {
      let mountsDir = "\(homeDir)/mountmate"
      return "\(mountsDir)/\(share.name)"
    }
  }

  /// Whether two mount point paths name the same folder. Compared
  /// case-insensitively (the default APFS volume is case-insensitive), which
  /// errs on the side of treating paths as the same.
  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    normalizedMountPath(lhs) == normalizedMountPath(rhs)
  }

  private static func normalizedMountPath(_ path: String) -> String {
    var standardized = (path as NSString).standardizingPath
    while standardized.count > 1 && standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    return standardized.lowercased()
  }

  /// Network mounts in the kernel mount table, or nil if it could not be
  /// read. This never touches the mount points themselves, so it cannot hang
  /// on an unresponsive server.
  private func currentMountTable() -> [MountedNetworkShare]? {
    MountTable.networkShares()
  }

  /// A mount accepted as a saved share's although its host is spelled
  /// differently. Remembers the share's endpoint at adoption time so the
  /// adoption is void once the share's server, path or protocol is edited.
  struct Adoption: Equatable {
    let mountPoint: String
    let shareProtocol: ShareProtocol
    let endpoint: MountedNetworkShare.Endpoint
  }

  /// Decides which saved share each mount is, in two passes:
  /// 1. exact host + path matches (`matches`) over all shares;
  /// 2. only for mounts no share matched exactly: still-valid adoptions.
  /// A share with an exact match never also claims a mount by adoption.
  /// An adoption is valid while its share exists with the same protocol and
  /// endpoint and an unclaimed mount with that share path is at its mount
  /// point; invalid adoptions are left out of the returned set.
  ///
  /// - Returns: the owning share ID per mount (aligned with `mounts`), and
  ///   the adoptions to keep.
  static func attributeMounts(
    _ mounts: [MountedNetworkShare], to shares: [NetworkShare], adoptions: [UUID: Adoption]
  ) -> (owners: [UUID?], adoptions: [UUID: Adoption]) {
    var owners = [UUID?](repeating: nil, count: mounts.count)
    var exactlyMatched = Set<UUID>()
    for (index, mount) in mounts.enumerated() {
      if let share = shares.first(where: { mount.matches($0) }) {
        owners[index] = share.id
        exactlyMatched.insert(share.id)
      }
    }

    var keptAdoptions: [UUID: Adoption] = [:]
    for (shareID, adoption) in adoptions {
      guard !exactlyMatched.contains(shareID),
        let share = shares.first(where: { $0.id == shareID }),
        share.shareProtocol == adoption.shareProtocol,
        MountedNetworkShare.endpoint(for: share) == adoption.endpoint,
        let index = mounts.indices.first(where: {
          owners[$0] == nil && samePath(mounts[$0].mountPoint, adoption.mountPoint)
            && hasSameSharePath(mounts[$0], share)
        })
      else { continue }
      owners[index] = shareID
      keptAdoptions[shareID] = adoption
    }
    return (owners, keptAdoptions)
  }

  /// The mounts in `mountTable` that are `share`, attributed against the
  /// share list of the last refresh (with `share` itself up to date).
  private func mounts(of share: NetworkShare, in mountTable: [MountedNetworkShare])
    -> [MountedNetworkShare]
  {
    let (snapshot, currentAdoptions) = parseLock.withLock { (savedSharesSnapshot, adoptions) }
    var shares = snapshot
    if let index = shares.firstIndex(where: { $0.id == share.id }) {
      shares[index] = share
    } else {
      shares.append(share)
    }
    let owners = Self.attributeMounts(mountTable, to: shares, adoptions: currentAdoptions).owners
    return mountTable.indices.filter { owners[$0] == share.id }.map { mountTable[$0] }
  }

  /// Forgets any adopted mount for a share (call when it is edited or removed).
  func forgetAdoption(forShareID shareID: UUID) {
    parseLock.withLock { _ = adoptions.removeValue(forKey: shareID) }
  }

  /// Same protocol and share path, whatever the host is called.
  static func hasSameSharePath(_ mounted: MountedNetworkShare, _ share: NetworkShare)
    -> Bool
  {
    mounted.shareProtocol == share.shareProtocol
      && mounted.endpoint?.path == MountedNetworkShare.endpoint(for: share).path
  }

  private func adopt(_ mountPoint: String, for share: NetworkShare) {
    Log.network.info(
      "Share \(share.name, privacy: .private) is already mounted at \(mountPoint, privacy: .private) under another server name."
    )
    let adoption = Adoption(
      mountPoint: mountPoint, shareProtocol: share.shareProtocol,
      endpoint: MountedNetworkShare.endpoint(for: share))
    parseLock.withLock { adoptions[share.id] = adoption }
  }

  /// Where `share` is mounted right now according to a fresh mount table, or
  /// nil if it is not mounted. Prefers `lastKnown` (from the last refresh)
  /// when the share is still mounted there. If the mount table cannot be
  /// read, falls back to `lastKnown`, then the configured mount point.
  /// Blocking; must not run on the main thread.
  private func liveMountPoint(for share: NetworkShare, lastKnown: String?) -> String? {
    guard let mountTable = currentMountTable() else {
      return lastKnown ?? configuredMountPoint(for: share)
    }
    let shareMounts = self.mounts(of: share, in: mountTable)
    if let lastKnown,
      let mount = shareMounts.first(where: { Self.samePath($0.mountPoint, lastKnown) })
    {
      return mount.mountPoint
    }
    return shareMounts.first?.mountPoint
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
}
