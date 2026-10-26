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

class NetworkMountManager: ObservableObject, NetworkShareMounterHost {
  static let shared = NetworkMountManager()

  private(set) lazy var mounter = NetworkShareMounter(host: self)

  @Published var mountedShareIDs: Set<UUID> = []
  /// Where each saved (and manually connected) share is currently mounted,
  /// from the last status refresh. Main thread only.
  private(set) var mountPointsByShareID: [UUID: String] = [:]
  /// Total and free bytes of each mounted share, from the last status refresh.
  @Published private(set) var usageByShareID: [UUID: ShareUsage] = [:]
  @Published var manuallyConnectedShares: [NetworkShare] = []
  @Published var isUnmountingManualShares = false

  private var manualSharesDictionary: [String: NetworkShare] = [:]

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

    // Refresh share status on mount/unmount/wake events (debounced so a burst of
    // events reads the mount table once), instead of on every disk refresh.
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
      NSWorkspace.didWakeNotification,
    ] {
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
    var results = [FileSystemUsage.Outcome?](repeating: nil, count: mounts.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: mounts.count) { index in
      let result = FileSystemUsage.read(atPath: mounts[index].value)
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
  /// mount operation and its result; see `NetworkShareMounter`.
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
    mounter.mount(share: share, userInitiated: userInitiated, completion: completion)
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
  func currentMountTable() -> [MountedNetworkShare]? {
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
  func mounts(of share: NetworkShare, in mountTable: [MountedNetworkShare])
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

  func adopt(_ mountPoint: String, for share: NetworkShare) {
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
}
