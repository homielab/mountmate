//  Created by homielab.com

import AppKit
import Foundation
import NetFS

/// A network mount reported by `/sbin/mount`, independent of protocol.
struct MountedNetworkShare {
  let source: String
  let mountPoint: String
  let shareProtocol: ShareProtocol

  init?(mountOutputLine: String) {
    // `/sbin/mount` prints `<source> on <mount point> (<fs>, <options>)`.
    // The mount point is printed verbatim and may itself contain " on " or
    // parentheses, so the options are the LAST " (" group, which must close
    // at the end of the line, and the source ends at the FIRST " on " (SMB
    // and AFP sources are percent-encoded and never contain a literal space).
    // Matching the filesystem name only inside that trailing group means a
    // mount point containing e.g. "smbfs" is never mistaken for one.
    let line = mountOutputLine.trimmingCharacters(in: .whitespaces)
    guard line.hasSuffix(")"),
      let openRange = line.range(of: " (", options: .backwards)
    else { return nil }

    let options = line[openRange.upperBound..<line.index(before: line.endIndex)]
    let fileSystem =
      options
      .split(separator: ",")
      .first?
      .trimmingCharacters(in: .whitespaces)
      .lowercased() ?? ""

    guard let shareProtocol = ShareProtocol.from(mountFilesystemName: fileSystem) else {
      return nil
    }

    let mountPart = line[..<openRange.lowerBound]
    guard let onRange = mountPart.range(of: " on ") else { return nil }

    let source = mountPart[..<onRange.lowerBound].trimmingCharacters(in: .whitespaces)
    let mountPoint = mountPart[onRange.upperBound...].trimmingCharacters(in: .whitespaces)
    guard !source.isEmpty, !mountPoint.isEmpty else { return nil }

    self.source = source
    self.mountPoint = mountPoint
    self.shareProtocol = shareProtocol
  }

  /// Normalized server + path of a network share, compared exactly (never by
  /// substring, so "nas" does not match "nas2" or "nas.backup.lan").
  struct Endpoint: Equatable {
    let host: String
    let path: String
  }

  /// The endpoint this mount is connected to, parsed from its mount source.
  var endpoint: Endpoint? {
    Self.endpoint(fromMountSource: source, shareProtocol: shareProtocol)
  }

  /// True when this mount is the given saved share (same host and share path).
  func matches(_ share: NetworkShare) -> Bool {
    guard let mounted = endpoint, !mounted.host.isEmpty else { return false }
    return mounted == Self.endpoint(for: share)
  }

  /// Parses a `/sbin/mount` source:
  /// - SMB/AFP: `//[user[;domain]@]host[:port]/share[/sub]` (percent-encoded)
  /// - NFS: `host:/export/path` or `[v6addr]:/export/path`
  static func endpoint(fromMountSource source: String, shareProtocol: ShareProtocol)
    -> Endpoint?
  {
    switch shareProtocol {
    case .nfs:
      var rest = Substring(source)
      let host: Substring
      if rest.hasPrefix("[") {
        guard let close = rest.firstIndex(of: "]") else { return nil }
        host = rest[rest.index(after: rest.startIndex)..<close]
        rest = rest[rest.index(after: close)...]
        guard rest.hasPrefix(":") else { return nil }
        rest = rest.dropFirst()
      } else {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        host = rest[..<colon]
        rest = rest[rest.index(after: colon)...]
      }
      return Endpoint(host: normalizedHost(String(host)), path: normalizedPath(String(rest)))
    case .smb, .afp:
      var rest = Substring(source)
      while rest.hasPrefix("/") { rest = rest.dropFirst() }
      let authority: Substring
      let path: Substring
      if let slash = rest.firstIndex(of: "/") {
        authority = rest[..<slash]
        path = rest[slash...]
      } else {
        authority = rest
        path = ""
      }
      return Endpoint(host: normalizedHost(String(authority)), path: normalizedPath(String(path)))
    }
  }

  /// The endpoint a saved share points at, normalized like a mount source.
  static func endpoint(for share: NetworkShare) -> Endpoint {
    Endpoint(host: normalizedHost(share.server), path: normalizedPath(share.sharePath))
  }

  /// Reduces a host (as typed by the user or printed in a mount source) to a
  /// comparable form: drops any scheme, path, `user@` and `:port`, removes
  /// IPv6 brackets, percent-decodes, drops a trailing dot and lowercases.
  static func normalizedHost(_ raw: String) -> String {
    var host = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    if let schemeEnd = host.range(of: "://") {
      host = host[schemeEnd.upperBound...]
    }
    while host.hasPrefix("/") { host = host.dropFirst() }
    if let slash = host.firstIndex(of: "/") {
      host = host[..<slash]
    }
    // Usernames are percent-encoded in mount sources, so the last literal
    // "@" always separates user info from the host.
    if let at = host.lastIndex(of: "@") {
      host = host[host.index(after: at)...]
    }

    var result: String
    if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
      result = String(host[host.index(after: host.startIndex)..<close])
    } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
      // `host:port`. A bare IPv6 address has several colons and is kept.
      result = String(host[..<colon])
    } else {
      result = String(host)
    }
    result = result.removingPercentEncoding ?? result
    while result.hasSuffix(".") { result.removeLast() }
    result = result.lowercased()
    // Finder mounts found via Bonjour use the service name
    // ("NAS._smb._tcp.local"): treat it, "nas.local" and "nas" as one host.
    for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", ".local"]
    where result.hasSuffix(suffix) {
      result.removeLast(suffix.count)
      break
    }
    return result
  }

  /// Percent-decodes a share path, strips surrounding slashes and lowercases
  /// it (SMB/AFP share names are case-insensitive).
  static func normalizedPath(_ raw: String) -> String {
    let decoded = raw.removingPercentEncoding ?? raw
    return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
  }
}

class NetworkMountManager: ObservableObject {
  static let shared = NetworkMountManager()

  @Published var mountedShareIDs: Set<UUID> = []
  /// Where each saved (and manually connected) share is currently mounted,
  /// from the last status refresh. Main thread only.
  private(set) var mountPointsByShareID: [UUID: String] = [:]
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

  private init() {
    // Initial check
    refreshMountStatus()

    // Refresh share status on mount/unmount events (debounced so a burst of
    // events runs `/sbin/mount` once), instead of on every disk refresh.
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
      DispatchQueue.global(qos: .userInitiated).async {
        self.refreshMountStatus(savedShares: savedShares, completion: completion)
      }
    }
  }

  /// Background part of `refreshMountStatus(completion:)`.
  private func refreshMountStatus(savedShares: [NetworkShare], completion: (() -> Void)?) {
    let result = runProcess(executable: "/sbin/mount", arguments: [])
    guard result.succeeded, !result.stdout.isEmpty else {
      DispatchQueue.main.async { completion?() }
      return
    }
    let output = result.stdout

    let parsedData = self.parseMountedShares(from: output, savedShares: savedShares)

    DispatchQueue.main.async {
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

  private func parseMountedShares(from mountOutput: String, savedShares shares: [NetworkShare])
    -> (mountedUUIDs: Set<UUID>, manualShares: [NetworkShare], mountPoints: [UUID: String])
  {
    // Refreshes can run concurrently on background threads.
    parseLock.lock()
    defer { parseLock.unlock() }

    var mountedUUIDs = Set<UUID>()
    var mountPoints = [UUID: String]()
    var currentManualShareMountPoints = Set<String>()
    var manualShares = [NetworkShare]()

    let mountedShares = mountOutput.components(separatedBy: .newlines).compactMap {
      MountedNetworkShare(mountOutputLine: $0)
    }

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
      } else {
        // It's a manually connected share
        currentManualShareMountPoints.insert(mountedShare.mountPoint)

        if let existing = manualSharesDictionary[mountedShare.mountPoint] {
          manualShares.append(existing)
          mountPoints[existing.id] = mountedShare.mountPoint
        } else {
          // Parse the source
          var username = ""
          var server = ""
          var sharePath = ""

          switch mountedShare.shareProtocol {
          case .nfs:
            // NFS sources look like `server:/export/path`.
            let withoutSlashes = mountedShare.source
              .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = withoutSlashes.components(separatedBy: ":")
            server = components.first ?? ""
            sharePath = components.dropFirst().joined(separator: ":")
              .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          default:
            let urlString = mountedShare.source.replacingOccurrences(
              of: "//", with: "\(mountedShare.shareProtocol.urlScheme)://")
            if let url = URL(string: urlString) {
              username = url.user ?? ""
              server = url.host ?? ""
              sharePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
              server = "Unknown"
              sharePath = "Share"
            }
          }

          if sharePath.isEmpty {
            sharePath = mountedShare.mountPoint.components(separatedBy: "/").last ?? "Share"
          }

          // The last path component, so the name (the default mount folder
          // if imported) never contains "/" ("volume1/data" → "data").
          let name = sharePath.split(separator: "/").last.map(String.init) ?? sharePath
          let newShare = NetworkShare(
            id: UUID(),
            name: name,
            server: server,
            sharePath: sharePath,
            username: username,
            mountAtLogin: false,
            keepMounted: false,
            shareProtocol: mountedShare.shareProtocol,
            // Not the current mount path: if this share is imported, its
            // later mounts must use MountMate's default user-owned location
            // (e.g. not /Volumes/public, which needs admin rights). The
            // current location is tracked in `mountPointsByShareID`.
            customMountPoint: nil
          )
          manualSharesDictionary[mountedShare.mountPoint] = newShare
          manualShares.append(newShare)
          mountPoints[newShare.id] = mountedShare.mountPoint
        }
      }
    }

    // Clean up old manual shares that are no longer mounted
    manualSharesDictionary = manualSharesDictionary.filter {
      currentManualShareMountPoints.contains($0.key)
    }

    return (mountedUUIDs, manualShares, mountPoints)
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
      DispatchQueue.main.async { waiters.forEach { $0(success, error) } }
    }

    // Everything below can block (`/sbin/mount`, the Keychain, NetFS), so
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
      print("Retrying \(share.name) although an earlier NetFS call is stalled (\(Int(age))s).")
    }

    // Decide "already mounted" from the kernel mount table only. stat() and
    // other file checks on a mount point whose server stopped responding can
    // block indefinitely (which used to wedge keep-alive sweeps).
    let mountTable = currentMountTable()

    // Already mounted (at our target path or elsewhere)?
    if let existingMount = mountTable.flatMap({ mounts(of: share, in: $0).first }) {
      print("Share \(share.name) is already mounted at \(existingMount.mountPoint)")
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
          share.name, mountPoint, sanitizeError(occupant.source)))
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
          "Cannot create mount point at \"\(mountPoint)\".\n\nThis location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/\(share.name)) or leave the Custom Mount Point empty to use the default location."
        )
      } else {
        finish(
          false, "Failed to create mount point at \"\(mountPoint)\": \(error.localizedDescription)")
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
        print("Unmounting \(share.name) again: it was ejected during an automatic mount.")
        _ = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
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
    let sanitized = sanitizeError(rawError)
    // Detect permission-related mount failures
    let lower = sanitized.lowercased()
    if lower.contains("permission denied") || lower.contains("operation not permitted")
      || lower.contains("not owner")
    {
      return .failed(mountLocationPermissionMessage(share: share, mountPoint: mountPoint))
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
      return .failed("Invalid share configuration")
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
    return .failed(netFSErrorMessage(status, share: share, mountPoint: mountPoint))
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
        print("NetFS mount of \(share.name) finished after timing out (status \(status)).")
        // An automatic mount that landed late although the user ejected the
        // share meanwhile: unmount it again, but only at our own folder.
        if status == 0, undoIfSuppressed,
          KeepAliveManager.shared.isSuppressed(shareID: share.id),
          let mountTable = self.currentMountTable(),
          mountTable.contains(where: {
            Self.samePath($0.mountPoint, mountPoint) && Self.hasSameSharePath($0, share)
          })
        {
          print("Unmounting \(share.name) again: it was ejected while the mount was pending.")
          _ = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
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

  /// Maps a NetFS / errno status to a readable message.
  private func netFSErrorMessage(_ status: Int32, share: NetworkShare, mountPoint: String)
    -> String
  {
    switch status {
    case EAUTH,
      -5045,  // ENETFSPWDNEEDSCHANGE
      -5046,  // ENETFSPWDPOLICY
      -5999:  // ENETFSACCOUNTRESTRICTED
      return String(
        format: NSLocalizedString(
          "Authentication failed for “%@”. Check the username and password.",
          comment: "Network share mount error"),
        share.name)
    case EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN, ECONNREFUSED:
      return String(
        format: NSLocalizedString(
          "Could not connect to the server “%@”. Check that it is turned on and reachable from this network.",
          comment: "Network share mount error"),
        share.server)
    case ENOENT,
      -5998:  // ENETFSNOSHARESAVAIL
      return String(
        format: NSLocalizedString(
          "The share “%@” was not found on the server “%@”.",
          comment: "Network share mount error"),
        share.sharePath, share.server)
    case EEXIST:
      return String(
        format: NSLocalizedString(
          "“%@” is already connected, probably under a different server name (for example in Finder). Disconnect it there and try again.",
          comment: "Network share mount error"),
        share.name)
    case EBUSY:
      return String(
        format: NSLocalizedString(
          "Another volume is already mounted at “%@”.",
          comment: "Network share mount error"),
        mountPoint)
    case EPERM, EACCES:
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      if !mountPoint.hasPrefix(home + "/") {
        return mountLocationPermissionMessage(share: share, mountPoint: mountPoint)
      }
      return String(
        format: NSLocalizedString(
          "Access to the share “%@” was denied by the server.",
          comment: "Network share mount error"),
        share.name)
    default:
      if status > 0, let description = strerror(status) {
        return String(
          format: NSLocalizedString(
            "Could not mount “%@”: %@ (error %d).", comment: "Network share mount error"),
          share.name, String(cString: description), status)
      }
      return String(
        format: NSLocalizedString(
          "Could not mount “%@” (error %d).", comment: "Network share mount error"),
        share.name, status)
    }
  }

  private func mountLocationPermissionMessage(share: NetworkShare, mountPoint: String) -> String {
    "Could not mount \"\(share.name)\" at \"\(mountPoint)\".\n\nThe mount location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/\(share.name)) or leave the Custom Mount Point empty to use the default location."
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
          print("Failed to auto-mount \(share.name): \(error ?? "Unknown error")")
        } else {
          print("Successfully auto-mounted \(share.name)")
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
        _ = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
      }
      DispatchQueue.main.async {
        // Automatic: must not clear keep-alive suppression or backoff state.
        self.mount(share: share, userInitiated: false) { success, _ in
          completion?(success)
        }
      }
    }
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
    if let customPath = share.customMountPoint, !customPath.isEmpty {
      let expandedPath = (customPath as NSString).expandingTildeInPath
      if !expandedPath.hasPrefix("/") {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/\(expandedPath)"
      } else {
        return expandedPath
      }
    } else {
      let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
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

  /// Network mounts listed by `/sbin/mount`, or nil if it could not be read.
  /// This only reads the kernel mount table and never touches the mount
  /// points themselves, so it cannot hang on an unresponsive server.
  private func currentMountTable() -> [MountedNetworkShare]? {
    let result = runProcess(executable: "/sbin/mount", arguments: [])
    guard result.succeeded, !result.stdout.isEmpty else { return nil }
    return
      result.stdout
      .components(separatedBy: .newlines)
      .compactMap { MountedNetworkShare(mountOutputLine: $0) }
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
    print("Share \(share.name) is already mounted at \(mountPoint) under another server name.")
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

  /// Strips credentials from network URLs in error strings to prevent password
  /// leaks. e.g. "smb://user:p%40ss@host/share" → "smb://user:***@host/share"
  private func sanitizeError(_ error: String) -> String {
    // Match protocol://user:password@host patterns (password may be URL-encoded)
    let pattern = "((?:smb|afp|nfs)://[^:/@]+:)([^@]+)(@)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return error
    }
    return regex.stringByReplacingMatches(
      in: error,
      range: NSRange(error.startIndex..., in: error),
      withTemplate: "$1***$3"
    )
  }
}
