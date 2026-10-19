//  Created by homielab.com

import Combine
import Foundation

class PersistenceManager: ObservableObject {
  static let shared = PersistenceManager()

  private let protectedVolumesKey = "mountmate_protectedVolumes_v4"
  private let ignoredVolumesKey = "mountmate_ignoredVolumes_v4"
  private let blockedVolumesKey = "mountmate_blockedVolumes_v1"
  private let keepAliveVolumesKey = "mountmate_keepAliveVolumes_v1"
  private let networkSharesKey = "mountmate_networkShares_v1"
  private let customMountPointsKey = "mountmate_customMountPoints_v1"

  @Published var protectedVolumes: [ManagedVolumeInfo]
  @Published var ignoredVolumes: [ManagedVolumeInfo]
  @Published var blockedVolumes: [ManagedVolumeInfo]
  @Published var keepAliveVolumes: [ManagedVolumeInfo]
  @Published var networkShares: [NetworkShare]
  @Published var customMountPoints: [VolumeCustomMountPoint]
  /// Volumes pinned to the top of the menu bar list, in the order they were
  /// pinned. Stored by composite ID so pins survive reconnecting the drive.
  @Published var pinnedVolumeIDs: [String] =
    UserDefaults.standard.stringArray(forKey: "pinnedVolumeIDs") ?? []
  {
    didSet { UserDefaults.standard.set(pinnedVolumeIDs, forKey: "pinnedVolumeIDs") }
  }

  func isPinned(_ volume: Volume) -> Bool {
    guard let id = volume.compositeId else { return false }
    return pinnedVolumeIDs.contains(id)
  }

  /// Returns false when the volume has no stable identifier to pin by.
  @discardableResult
  func setPinned(_ pinned: Bool, volume: Volume) -> Bool {
    guard let id = volume.compositeId else { return false }
    if pinned {
      if !pinnedVolumeIDs.contains(id) { pinnedVolumeIDs.append(id) }
    } else {
      pinnedVolumeIDs.removeAll { $0 == id }
    }
    return true
  }

  static let mountMateFstabPrefix = "# MountMate custom mount:"
  static let mountMateBlockPrefix = "# MountMate block:"

  /// When on, every blocked volume also gets a `noauto` rule in /etc/fstab,
  /// so macOS itself skips mounting it at startup — before MountMate (or any
  /// login item) is running. Off by default because each change to
  /// /etc/fstab needs the administrator password.
  @Published private(set) var blockAtStartup: Bool = UserDefaults.standard.bool(
    forKey: "blockAtStartup")

  /// Volume UUIDs (uppercased) that currently have a MountMate startup-block
  /// rule in /etc/fstab. Main thread only. Not @Published: no view shows it,
  /// and publishing would redraw every observer of this manager.
  private(set) var fstabBlockedVolumeUUIDs: Set<String> = []

  /// Serializes every startup-block read-modify-write cycle of /etc/fstab so
  /// concurrent block, unblock and reconcile actions cannot interleave.
  private let fstabQueue = DispatchQueue(label: "com.homielab.mountmate.fstab")
  private var isFstabReconcilePending = false
  /// Set when a background startup-block update fails (e.g. its admin prompt
  /// is cancelled). Background updates then stay quiet — also across
  /// launches — until the user blocks, unblocks or toggles the setting.
  /// Only touched on `fstabQueue`.
  private var backgroundFstabUpdateDeclined: Bool {
    get { UserDefaults.standard.bool(forKey: "startupBlockBackgroundDeclined") }
    set { UserDefaults.standard.set(newValue, forKey: "startupBlockBackgroundDeclined") }
  }

  private init() {
    self.protectedVolumes = Self.load(from: protectedVolumesKey)
    self.ignoredVolumes = Self.load(from: ignoredVolumesKey)
    self.blockedVolumes = Self.load(from: blockedVolumesKey)
    self.keepAliveVolumes = Self.load(from: keepAliveVolumesKey)
    self.networkShares = Self.load(from: networkSharesKey)
    self.customMountPoints = Self.load(from: customMountPointsKey)
    self.fstabBlockedVolumeUUIDs = Self.managedFstabVolumeUUIDs(
      kinds: [Self.mountMateBlockPrefix], in: Self.readSystemFstabContents())
  }

  // MARK: - Actions

  @discardableResult
  func protect(volume: Volume) -> Bool {
    guard let info = volume.managedVolumeInfo else { return false }
    guard !protectedVolumes.contains(where: { $0.id == info.id }) else { return true }
    protectedVolumes.append(info)
    saveProtectedVolumes()
    return true
  }

  func unprotect(info: ManagedVolumeInfo) {
    protectedVolumes.removeAll { $0.id == info.id }
    saveProtectedVolumes()
  }

  @discardableResult
  func ignore(volume: Volume) -> Bool {
    guard let info = volume.managedVolumeInfo else { return false }
    guard !ignoredVolumes.contains(where: { $0.id == info.id }) else { return true }
    ignoredVolumes.append(info)
    saveIgnoredVolumes()
    return true
  }

  func ignore(disk: PhysicalDisk) {
    let infos =
      disk.partitions.compactMap { volume -> ManagedVolumeInfo? in
        guard let diskUUID = volume.diskUUID else { return nil }
        return ManagedVolumeInfo(
          volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
      }
      + disk.containers.flatMap { $0.volumes }.compactMap { volume -> ManagedVolumeInfo? in
        guard let diskUUID = volume.diskUUID else { return nil }
        return ManagedVolumeInfo(
          volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
      }

    for info in infos {
      if !ignoredVolumes.contains(where: { $0.id == info.id }) {
        ignoredVolumes.append(info)
      }
    }
    saveIgnoredVolumes()
  }

  func unignore(info: ManagedVolumeInfo) {
    ignoredVolumes.removeAll { $0.id == info.id }
    saveIgnoredVolumes()
  }

  @discardableResult
  func block(volume: Volume) -> Bool {
    guard let info = volume.managedVolumeInfo else { return false }
    guard !blockedVolumes.contains(where: { $0.id == info.id }) else { return true }
    blockedVolumes.append(info)
    saveBlockedVolumes()

    // Auto-reconnect conflicts with an explicit request to keep this volume
    // unmounted. DiskMounter enforces the block through Disk Arbitration while
    // MountMate is running, so do not leave a reconnect target behind.
    if let compositeId = volume.compositeId,
      keepAliveVolumes.contains(where: { $0.id == compositeId })
    {
      keepAliveVolumes.removeAll { $0.id == compositeId }
      saveKeepAliveVolumes()
    }

    if blockAtStartup {
      reconcileStartupBlockRules(userInitiated: true)
    }
    return true
  }

  func unblock(info: ManagedVolumeInfo) {
    blockedVolumes.removeAll { $0.id == info.id }
    saveBlockedVolumes()

    // Remove the volume's startup rule even when the setting is off, so an
    // unblocked volume never stays blocked at boot. While the setting is on,
    // always reconcile: a rule for this volume may still be in flight on
    // fstabQueue (block then unblock during the password prompt) and not yet
    // reflected in fstabBlockedVolumeUUIDs. The queued reconcile runs after
    // it and removes the rule; when nothing changes it does not prompt.
    let hasKnownRule = Self.normalizedSystemVolumeUUID(info.volumeUUID)
      .map { fstabBlockedVolumeUUIDs.contains($0) } ?? false
    if blockAtStartup || hasKnownRule {
      reconcileStartupBlockRules(userInitiated: true)
    }
  }

  @discardableResult
  func setKeepAlive(_ enabled: Bool, volume: Volume) -> Bool {
    guard let info = volume.managedVolumeInfo else { return false }
    if enabled {
      guard !keepAliveVolumes.contains(where: { $0.id == info.id }) else { return true }
      keepAliveVolumes.append(info)
    } else {
      keepAliveVolumes.removeAll { $0.id == info.id }
    }
    saveKeepAliveVolumes()
    return true
  }

  func unkeepAlive(info: ManagedVolumeInfo) {
    keepAliveVolumes.removeAll { $0.id == info.id }
    saveKeepAliveVolumes()
  }

  func isVolumeKeepAlive(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return keepAliveVolumes.contains { $0.id == compositeId }
  }

  func addNetworkShare(_ share: NetworkShare) {
    networkShares.append(share)
    saveNetworkShares()
  }

  /// Adds discovered shares without creating duplicate entries for the same SMB endpoint.
  @discardableResult
  func addNetworkSharesIfNeeded(_ shares: [NetworkShare]) -> Int {
    var addedCount = 0

    for share in shares where !containsNetworkShare(matching: share) {
      networkShares.append(share)
      addedCount += 1
    }

    if addedCount > 0 {
      saveNetworkShares()
    }
    return addedCount
  }

  func containsNetworkShare(matching share: NetworkShare) -> Bool {
    let server = share.server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let path =
      share.sharePath
      .removingPercentEncoding?
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
      ?? share.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()

    return networkShares.contains { existing in
      let existingServer = existing.server
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let existingPath =
        existing.sharePath
        .removingPercentEncoding?
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .lowercased()
        ?? existing.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
      return existingServer == server && existingPath == path
    }
  }

  func updateNetworkShare(_ share: NetworkShare) {
    if let index = networkShares.firstIndex(where: { $0.id == share.id }) {
      networkShares[index] = share
      saveNetworkShares()
    }
  }

  func removeNetworkShare(_ share: NetworkShare) {
    networkShares.removeAll { $0.id == share.id }
    KeychainManager.shared.delete(account: share.id.uuidString)
    saveNetworkShares()
  }

  func customMountPoint(for volume: Volume) -> VolumeCustomMountPoint? {
    customMountPoints.first { $0.id == stableIdentifier(for: volume) }
  }

  func applyCustomMountPoint(_ mountPoint: String, selectedURL: URL?, for volume: Volume) -> String?
  {
    guard !isVolumeBlocked(volume) else {
      return NSLocalizedString(
        "Custom Mount Point Volume Blocked",
        comment: "Custom mount point blocked-volume error")
    }
    guard let volumeUUID = volumeUUIDForSystemMount(for: volume) else {
      return NSLocalizedString(
        "Custom Mount Point Requires UUID",
        comment: "Custom mount point system configuration error")
    }
    guard let fileSystemType = resolvedFstabFileSystemType(for: volume) else {
      return NSLocalizedString(
        "Custom Mount Point Unsupported File System",
        comment: "Custom mount point system configuration error")
    }

    do {
      let snapshot = try loadSystemFstabSnapshot()
      let currentContents = snapshot.contents
      let updatedContents = try updatedFstabContents(
        from: currentContents,
        for: volume,
        volumeUUID: volumeUUID,
        mountPoint: mountPoint,
        fileSystemType: fileSystemType
      )

      if updatedContents != currentContents {
        try installSystemFstabContents(updatedContents, expectedCurrent: snapshot.raw)
      }

      if let selectedURL, selectedURL.path == mountPoint {
        saveCustomMountPoint(url: selectedURL, for: volume)
      } else {
        saveCustomMountPoint(mountPoint, for: volume)
      }
      return nil
    } catch {
      return String(
        format: NSLocalizedString(
          "Custom Mount Point System Save Error",
          comment: "Custom mount point system configuration error"),
        error.localizedDescription)
    }
  }

  func saveCustomMountPoint(_ mountPoint: String, for volume: Volume) {
    saveCustomMountPoint(mountPoint, bookmarkData: nil, for: volume)
  }

  func saveCustomMountPoint(url: URL, for volume: Volume) {
    let bookmarkData = try? url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    saveCustomMountPoint(url.path, bookmarkData: bookmarkData, for: volume)
  }

  func resolveCustomMountPointURL(for volume: Volume) -> URL? {
    guard let info = customMountPoint(for: volume) else { return nil }
    guard let bookmarkData = info.bookmarkData else {
      return URL(fileURLWithPath: info.mountPoint)
    }

    var isStale = false
    if let resolvedURL = try? URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) {
      if isStale {
        saveCustomMountPoint(url: resolvedURL, for: volume)
      }
      return resolvedURL
    }

    return URL(fileURLWithPath: info.mountPoint)
  }

  @discardableResult
  func withAccessToCustomMountPoint<T>(for volume: Volume, _ body: (URL) throws -> T) rethrows -> T?
  {
    guard let url = resolveCustomMountPointURL(for: volume) else { return nil }
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return try body(url)
  }

  private func saveCustomMountPoint(
    _ mountPoint: String, bookmarkData: Data?, for volume: Volume
  ) {
    let identifier = stableIdentifier(for: volume)
    let info = VolumeCustomMountPoint(
      volumeUUID: volume.id,
      backingDiskIdentifier: backingDiskIdentifier(for: volume),
      name: volume.name,
      mountPoint: mountPoint,
      bookmarkData: bookmarkData
    )

    if let index = customMountPoints.firstIndex(where: { $0.id == identifier }) {
      customMountPoints[index] = info
    } else {
      customMountPoints.append(info)
    }
    saveCustomMountPoints()
  }

  func clearCustomMountPoint(for volume: Volume) {
    customMountPoints.removeAll { $0.id == stableIdentifier(for: volume) }
    saveCustomMountPoints()
  }

  func removeCustomMountPoint(for volume: Volume) -> String? {
    do {
      let snapshot = try loadSystemFstabSnapshot()
      let currentContents = snapshot.contents
      let updatedContents = removingManagedFstabEntry(from: currentContents, for: volume)

      if updatedContents != currentContents {
        try installSystemFstabContents(updatedContents, expectedCurrent: snapshot.raw)
      }

      clearCustomMountPoint(for: volume)
      return nil
    } catch {
      return String(
        format: NSLocalizedString(
          "Custom Mount Point System Save Error",
          comment: "Custom mount point system configuration error"),
        error.localizedDescription)
    }
  }

  // MARK: - Volume Helpers

  /// Normalizes a volume identifier into an uppercased UUID string, or nil
  /// when the identifier is not a UUID (e.g. a fallback device name such as
  /// "disk4s2"), which cannot address a volume reliably across reboots.
  static func normalizedSystemVolumeUUID(_ raw: String) -> String? {
    guard let uuid = UUID(uuidString: raw) else { return nil }
    return uuid.uuidString
  }

  // MARK: - Startup Blocking (/etc/fstab)

  /// The Disk Arbitration approval callback only exists while MountMate is
  /// running, but macOS mounts connected volumes during startup, before login
  /// items launch. With "Block at Startup" on, each blocked volume is also
  /// written to /etc/fstab as `UUID=… none <fs> rw,noauto`, which makes macOS
  /// itself skip the automatic mount. Manual mounts (MountMate, Disk Utility,
  /// `diskutil mount`) still work.
  ///
  /// Rules can only be added while the volume is connected, because the
  /// filesystem type is read from it. A blocked volume that is not connected
  /// gets its rule the next time it appears and MountMate dissents its mount.

  /// Turns startup blocking on or off and syncs /etc/fstab right away (one
  /// administrator prompt, or none when there is nothing to change). If the
  /// update fails, the setting goes back to its previous value.
  func setBlockAtStartup(_ enabled: Bool) {
    guard enabled != blockAtStartup else { return }
    let previous = blockAtStartup
    blockAtStartup = enabled
    UserDefaults.standard.set(enabled, forKey: "blockAtStartup")

    reconcileStartupBlockRules(userInitiated: true) { [weak self] succeeded in
      // Only roll back if the user has not changed the setting again since.
      guard let self, !succeeded, self.blockAtStartup == enabled else { return }
      self.blockAtStartup = previous
      UserDefaults.standard.set(previous, forKey: "blockAtStartup")
    }
  }

  /// Called once shortly after launch. Adds rules for blocked volumes that
  /// were connected at boot without one, and removes leftover rules whose
  /// removal was cancelled earlier (e.g. after unblocking the last blocked
  /// volume, when the Disk Arbitration session is no longer running).
  /// Prompts only when /etc/fstab actually needs to change.
  func reconcileStartupBlockRulesAtLaunch() {
    guard blockAtStartup || !fstabBlockedVolumeUUIDs.isEmpty else { return }
    reconcileStartupBlockRules(userInitiated: false)
  }

  /// Schedules a coalesced background reconcile a few seconds out. Called
  /// when a blocked volume's auto-mount was just dissented: the volume is
  /// connected at that moment, so its missing rule can be added.
  func scheduleStartupBlockReconcile() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.blockAtStartup, !self.isFstabReconcilePending else { return }
      self.isFstabReconcilePending = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
        guard let self else { return }
        self.isFstabReconcilePending = false
        self.reconcileStartupBlockRules(userInitiated: false)
      }
    }
  }

  /// Syncs MountMate's startup-block rules in /etc/fstab with the blocked
  /// list: adds rules for connected blocked volumes that lack one (only when
  /// the setting is on) and removes rules that are no longer wanted. Writes
  /// /etc/fstab at most once. Must be called on the main thread.
  ///
  /// - Parameters:
  ///   - userInitiated: Explicit user actions always try, even after an
  ///     earlier admin prompt was cancelled; background reconciles do not.
  ///   - completion: Called on the main thread with false if the update failed.
  func reconcileStartupBlockRules(
    userInitiated: Bool, completion: ((Bool) -> Void)? = nil
  ) {
    fstabQueue.async { [weak self] in
      guard let self else { return }
      if userInitiated {
        self.backgroundFstabUpdateDeclined = false
      } else if self.backgroundFstabUpdateDeclined {
        return
      }

      // Read the wanted state when the job runs, not when it was queued, so
      // jobs queued behind a password prompt act on the latest settings.
      // Several queued jobs collapse naturally: once one has applied the
      // current state, the rest find nothing to change and do not prompt.
      // (Safe: the main thread never waits on fstabQueue.)
      let (enabled, blockedInfos) = DispatchQueue.main.sync {
        (self.blockAtStartup, self.blockedVolumes)
      }

      do {
        try self.applyStartupBlockRules(
          enabled: enabled, blockedInfos: blockedInfos, attemptsLeft: 2)
        DispatchQueue.main.async { completion?(true) }
      } catch {
        if userInitiated {
          self.handleStartupBlockError(error)
        } else {
          // No alert for updates the user did not just ask for.
          self.backgroundFstabUpdateDeclined = true
          print(
            "⚠️ Background startup block update failed; not retrying until the next user action: \(error.localizedDescription)"
          )
        }
        DispatchQueue.main.async { completion?(false) }
      }
    }
  }

  /// One read-compute-write cycle of `reconcileStartupBlockRules`. Runs on
  /// `fstabQueue`. Retries when /etc/fstab changed between the read and the
  /// privileged write (e.g. a custom mount point was saved meanwhile).
  private func applyStartupBlockRules(
    enabled: Bool, blockedInfos: [ManagedVolumeInfo], attemptsLeft: Int
  ) throws {
    do {
      let snapshot = try self.loadSystemFstabSnapshot()
      let contents = snapshot.contents
      let present = Self.managedFstabVolumeUUIDs(
        kinds: [Self.mountMateBlockPrefix], in: contents)
      let desired: [String: ManagedVolumeInfo] =
        enabled
        ? Dictionary(
          blockedInfos.compactMap { info in
            Self.normalizedSystemVolumeUUID(info.volumeUUID).map { ($0, info) }
          }, uniquingKeysWith: { first, _ in first })
        : [:]

      let stale = present.subtracting(desired.keys)
      var additions: [(uuid: String, fileSystemType: String, info: ManagedVolumeInfo)] = []
      for (uuid, info) in desired where !present.contains(uuid) {
        if Self.hasOtherFstabEntry(volumeUUID: uuid, in: contents) {
          print(
            "ℹ️ “\(info.name)” already has an /etc/fstab entry; not adding a startup block rule."
          )
          continue
        }
        switch self.startupBlockEligibility(forVolumeUUID: uuid) {
        case .eligible(let fileSystemType):
          additions.append((uuid, fileSystemType, info))
        case .notConnected:
          print(
            "ℹ️ “\(info.name)” is not connected; its startup block rule will be added when it next appears."
          )
        case .ineligible(let reason):
          print("ℹ️ No startup block rule for “\(info.name)”: \(reason).")
        }
      }

      guard !stale.isEmpty || !additions.isEmpty else {
        self.refreshFstabBlockedUUIDs(from: contents)
        return
      }

      var updated = contents
      for uuid in stale {
        updated = Self.removingManagedFstabEntries(
          volumeUUID: uuid, kinds: [Self.mountMateBlockPrefix], from: updated)
      }
      updated = Self.trimmedFstabContents(updated)
      for addition in additions.sorted(by: { $0.uuid < $1.uuid }) {
        updated += Self.blockedFstabEntry(
          volumeUUID: addition.uuid, fileSystemType: addition.fileSystemType,
          identifier: addition.info.id)
      }

      try self.installSystemFstabContents(updated, expectedCurrent: snapshot.raw)
      self.refreshFstabBlockedUUIDs(from: updated)
      print(
        "✅ Startup block rules updated (\(additions.count) added, \(stale.count) removed).")
    } catch let error as NSError
      where error.domain == "MountMate" && error.code == Self.fstabChangedErrorCode
        && attemptsLeft > 1
    {
      print("ℹ️ /etc/fstab changed during the update; retrying with the new contents.")
      try applyStartupBlockRules(
        enabled: enabled, blockedInfos: blockedInfos, attemptsLeft: attemptsLeft - 1)
    }
  }

  enum StartupBlockEligibility: Equatable {
    case eligible(fileSystemType: String)
    case notConnected
    case ineligible(String)
  }

  /// Filesystem types that may get a `rw,noauto` rule: built-in macOS drivers
  /// that mount read-write anyway. Not NTFS: `rw` in /etc/fstab turns on
  /// Apple's experimental NTFS write support, which can corrupt the disk when
  /// it is later mounted by hand. Not third-party drivers (Paragon, Tuxera,
  /// macFUSE…), so a rule can never change which driver mounts a disk. Those
  /// disks keep the runtime block only.
  static let startupBlockFileSystemTypes: Set<String> = ["apfs", "hfs", "exfat", "msdos"]

  /// APFS roles that may get a startup rule. Any other role (System, Data,
  /// Preboot, Recovery, VM, Update, xART, Hardware…) is part of macOS, and a
  /// `noauto` rule for it could stop the Mac from starting up.
  static let startupBlockAllowedAPFSRoles: Set<String> = ["Backup"]

  /// Boot volume's APFS container (e.g. "disk3"), resolved once per launch.
  /// A failed lookup is not cached. Only touched on `fstabQueue`.
  private var cachedBootAPFSContainer: String?

  private func startupBlockEligibility(forVolumeUUID uuid: String) -> StartupBlockEligibility {
    guard let plist = diskInfo(for: uuid) else { return .notConnected }

    if cachedBootAPFSContainer == nil {
      cachedBootAPFSContainer = diskInfo(for: "/")?["APFSContainerReference"] as? String
    }

    var roles: [String]?
    if let container = plist["APFSContainerReference"] as? String {
      roles = apfsRoles(forVolumeUUID: uuid, container: container)
    }

    return Self.startupBlockEligibility(
      plist: plist, bootAPFSContainer: cachedBootAPFSContainer, apfsRoles: roles)
  }

  /// Decides whether a connected volume may get a startup rule, from its
  /// `diskutil info -plist` output. Errs on the side of no rule: a skipped
  /// volume is still blocked at runtime, while a wrong rule affects boot.
  static func startupBlockEligibility(
    plist: [String: Any], bootAPFSContainer: String?, apfsRoles: [String]?
  ) -> StartupBlockEligibility {
    let mountPoint = (plist["MountPoint"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if mountPoint == "/" || mountPoint.hasPrefix("/System/Volumes/") {
      return .ineligible("it is a macOS system volume")
    }

    let container = plist["APFSContainerReference"] as? String
    if let container {
      // Fail closed: without knowing the startup disk's container, no APFS
      // volume can be shown to be outside it.
      guard let bootAPFSContainer else {
        return .ineligible("the startup disk's APFS container could not be determined")
      }
      if container == bootAPFSContainer {
        return .ineligible("it is in the startup disk's APFS container")
      }
    }

    guard let rawType = (plist["FilesystemType"] as? String)?.lowercased(),
      startupBlockFileSystemTypes.contains(rawType)
    else {
      return .ineligible("its file system is not handled by a built-in macOS driver")
    }

    if rawType == "apfs" || container != nil {
      // Unknown roles are treated as system roles.
      guard let apfsRoles, Set(apfsRoles).isSubset(of: startupBlockAllowedAPFSRoles) else {
        return .ineligible("it has a macOS system role")
      }
    }

    return .eligible(fileSystemType: rawType)
  }

  /// APFS roles of a volume, or nil when they cannot be determined.
  private func apfsRoles(forVolumeUUID uuid: String, container: String) -> [String]? {
    let result = runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist", container])
    guard result.succeeded, let data = result.stdout.data(using: .utf8),
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any],
      let containers = plist["Containers"] as? [[String: Any]]
    else { return nil }

    for containerInfo in containers {
      for volume in containerInfo["Volumes"] as? [[String: Any]] ?? [] {
        if let volumeUUID = volume["APFSVolumeUUID"] as? String,
          volumeUUID.caseInsensitiveCompare(uuid) == .orderedSame
        {
          return volume["Roles"] as? [String] ?? []
        }
      }
    }
    return nil
  }

  /// The /etc/fstab comment+rule pair for a blocked volume. `none` as the
  /// mount point plus `noauto` makes macOS skip the automatic mount while
  /// leaving manual mounts possible.
  static func blockedFstabEntry(
    volumeUUID: String, fileSystemType: String, identifier: String
  ) -> String {
    "\(mountMateBlockPrefix) \(identifier)\nUUID=\(volumeUUID) none \(fileSystemType) rw,noauto\n"
  }

  private func refreshFstabBlockedUUIDs(from contents: String) {
    let uuids = Self.managedFstabVolumeUUIDs(kinds: [Self.mountMateBlockPrefix], in: contents)
    DispatchQueue.main.async { [weak self] in
      self?.fstabBlockedVolumeUUIDs = uuids
    }
  }

  private func handleStartupBlockError(_ error: Error) {
    print("⚠️ Failed to update startup block rules in /etc/fstab: \(error.localizedDescription)")
    let message = error.localizedDescription
    DispatchQueue.main.async {
      DriveManager.shared.userActionError = AppAlert(
        title: NSLocalizedString("System Mount Rule Not Updated", comment: "Alert title"),
        message: String(
          format: NSLocalizedString(
            "System Mount Rule Update Failed", comment: "Alert message"),
          message),
        kind: .basic)
    }
  }

  // MARK: - Helper Checkers

  func isVolumeProtected(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return protectedVolumes.contains { $0.id == compositeId }
  }

  func isVolumeIgnored(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return ignoredVolumes.contains { $0.id == compositeId }
  }

  func isVolumeBlocked(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return blockedVolumes.contains { $0.id == compositeId }
  }

  private func stableIdentifier(for volume: Volume) -> String {
    "\(backingDiskIdentifier(for: volume))-\(volume.id)"
  }

  private func backingDiskIdentifier(for volume: Volume) -> String {
    volume.diskUUID ?? volume.deviceIdentifier
  }

  private func volumeUUIDForSystemMount(for volume: Volume) -> String? {
    volume.id == volume.deviceIdentifier ? nil : volume.id
  }

  private func resolvedFstabFileSystemType(for volume: Volume) -> String? {
    let plist = diskInfo(for: volume.deviceIdentifier)
    return Self.fstabFileSystemType(plist: plist, fallback: volume.fileSystemType)
  }

  private func diskInfo(for deviceIdentifier: String) -> [String: Any]? {
    guard !deviceIdentifier.isEmpty else { return nil }
    let result = runProcess(
      executable: "/usr/sbin/diskutil",
      arguments: ["info", "-plist", deviceIdentifier])
    guard result.succeeded, let data = result.stdout.data(using: .utf8) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
      as? [String: Any]
  }

  /// Maps a diskutil plist (plus a fallback raw value) to the filesystem type
  /// string used in /etc/fstab entries.
  static func fstabFileSystemType(plist: [String: Any]?, fallback: String?) -> String? {
    let candidates = [
      plist?["FilesystemType"] as? String,
      plist?["FilesystemName"] as? String,
      plist?["Content"] as? String,
      fallback,
    ].compactMap { $0 }

    for candidate in candidates {
      if let mapped = mapFstabFileSystemType(candidate) {
        return mapped
      }
    }

    return nil
  }

  static func mapFstabFileSystemType(_ rawValue: String) -> String? {
    let value = rawValue.lowercased()
    if value.contains("apfs") { return "apfs" }
    if value.contains("hfs") { return "hfs" }
    if value.contains("exfat") { return "exfat" }
    if value.contains("msdos") || value.contains("dos_fat") || value.contains("fat32")
      || value.contains("fat")
    {
      return "msdos"
    }
    if value.contains("ntfs") { return "ntfs" }

    let normalized = value.filter { $0.isLetter || $0.isNumber }
    return normalized.isEmpty ? nil : normalized
  }

  private static func readSystemFstabContents() -> String {
    guard let data = FileManager.default.contents(atPath: "/etc/fstab"),
      let contents = String(data: data, encoding: .utf8)
    else { return "" }
    return contents
  }

  /// /etc/fstab as text, plus the exact bytes it was decoded from. The
  /// privileged write compares against the bytes, so a re-encoding
  /// difference (e.g. a byte-order mark) can never make it fail forever.
  private struct FstabSnapshot {
    let contents: String
    let raw: Data
  }

  private func loadSystemFstabSnapshot() throws -> FstabSnapshot {
    let path = "/etc/fstab"
    guard FileManager.default.fileExists(atPath: path) else {
      return FstabSnapshot(contents: "", raw: Data())
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let contents = String(data: raw, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return FstabSnapshot(contents: contents, raw: raw)
  }

  private func updatedFstabContents(
    from contents: String,
    for volume: Volume,
    volumeUUID: String,
    mountPoint: String,
    fileSystemType: String
  ) throws -> String {
    let withoutManagedEntry = removingManagedFstabEntry(from: contents, for: volume)
    let activeLines = withoutManagedEntry.components(separatedBy: .newlines)

    if activeLines.contains(where: { isConflictingFstabEntry($0, volumeUUID: volumeUUID) }) {
      throw NSError(
        domain: "MountMate",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: NSLocalizedString(
            "Custom Mount Point System Conflict",
            comment: "Custom mount point system configuration error")
        ])
    }

    var normalized = Self.trimmedFstabContents(withoutManagedEntry)
    if !normalized.isEmpty {
      normalized += "\n"
    }

    let entryLine =
      "UUID=\(volumeUUID) \(fstabEscapedField(mountPoint)) \(fileSystemType) rw"
    normalized += "\(managedFstabComment(for: volume))\n\(entryLine)\n"
    return normalized
  }

  private func removingManagedFstabEntry(from contents: String, for volume: Volume) -> String {
    guard let volumeUUID = volumeUUIDForSystemMount(for: volume) else { return contents }
    return Self.removingManagedFstabEntries(
      volumeUUID: volumeUUID, kinds: [Self.mountMateFstabPrefix], from: contents)
  }

  /// Removes MountMate-managed comment+entry pairs of the given `kinds`
  /// (comment prefixes) that address `volumeUUID`. Matching by UUID keeps
  /// removal working even when the volume's last-known identifiers have
  /// changed.
  static func removingManagedFstabEntries(
    volumeUUID: String, kinds: Set<String>, from contents: String
  ) -> String {
    let lines = contents.components(separatedBy: .newlines)
    var filtered: [String] = []
    var index = 0

    while index < lines.count {
      if let kind = managedPairKind(at: index, in: lines), kinds.contains(kind),
        entryAddressesUUID(lines[index + 1], volumeUUID)
      {
        index += 2
        continue
      }
      filtered.append(lines[index])
      index += 1
    }

    return trimmedFstabContents(filtered.joined(separator: "\n"))
  }

  private static func managedFstabKind(of line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix(mountMateFstabPrefix) { return mountMateFstabPrefix }
    if trimmed.hasPrefix(mountMateBlockPrefix) { return mountMateBlockPrefix }
    return nil
  }

  /// The managed kind of the comment+entry pair starting at `index`, or nil.
  /// A startup-block comment only counts when the next line really is a
  /// MountMate block rule, so a comment left behind by a hand edit can never
  /// make the user's own following line look like MountMate's.
  private static func managedPairKind(at index: Int, in lines: [String]) -> String? {
    guard let kind = managedFstabKind(of: lines[index]), index + 1 < lines.count else {
      return nil
    }
    if kind == mountMateBlockPrefix && !isBlockRuleLine(lines[index + 1]) { return nil }
    return kind
  }

  /// `UUID=<uuid> none <fs> <options containing noauto>`
  static func isBlockRuleLine(_ line: String) -> Bool {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard fields.count >= 4, fields[0].hasPrefix("UUID="), fields[0].count > 5,
      fields[1] == "none"
    else { return false }
    return fields[3].split(separator: ",").contains("noauto")
  }

  /// Volume UUIDs (uppercased) addressed by the managed entries of `kinds`.
  static func managedFstabVolumeUUIDs(kinds: Set<String>, in contents: String) -> Set<String> {
    let lines = contents.components(separatedBy: .newlines)
    var uuids: Set<String> = []
    var index = 0

    while index < lines.count {
      if let kind = managedPairKind(at: index, in: lines), kinds.contains(kind) {
        let entry = lines[index + 1].trimmingCharacters(in: .whitespaces)
        if entry.hasPrefix("UUID=") {
          let uuid = entry.dropFirst("UUID=".count).prefix { !$0.isWhitespace }
          if !uuid.isEmpty {
            uuids.insert(String(uuid).uppercased())
          }
        }
        index += 2
        continue
      }
      index += 1
    }

    return uuids
  }

  /// True when an fstab line other than a MountMate startup-block rule
  /// addresses `volumeUUID` (a custom mount point, or a rule the user wrote
  /// by hand). A second line for the same volume would conflict, so no
  /// startup-block rule is added in that case.
  static func hasOtherFstabEntry(volumeUUID: String, in contents: String) -> Bool {
    let lines = contents.components(separatedBy: .newlines)
    var index = 0

    while index < lines.count {
      if managedPairKind(at: index, in: lines) == mountMateBlockPrefix {
        index += 2
        continue
      }
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if !trimmed.hasPrefix("#"), entryAddressesUUID(trimmed, volumeUUID) {
        return true
      }
      index += 1
    }
    return false
  }

  private static func entryAddressesUUID(_ line: String, _ volumeUUID: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("UUID=") else { return false }
    let uuid = trimmed.dropFirst("UUID=".count).prefix { !$0.isWhitespace }
    return uuid.lowercased() == volumeUUID.lowercased()
  }

  private static let fstabChangedErrorCode = 3
  private static let fstabChangedMarker = "MOUNTMATE_FSTAB_CHANGED"

  /// Writes /etc/fstab with administrator privileges.
  ///
  /// `expectedCurrent` is the exact bytes the caller based `contents` on. The
  /// privileged shell checks /etc/fstab still matches it before writing, so
  /// two writers (custom mount points on the main thread, startup-block
  /// rules on `fstabQueue`) can never silently overwrite each other's change
  /// while one of them waits at the password prompt.
  private func installSystemFstabContents(_ contents: String, expectedCurrent: Data) throws {
    let normalizedContents = Self.trimmedFstabContents(contents)
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory
      .appendingPathComponent("mountmate-fstab-\(UUID().uuidString)")
    let expectedURL = fileManager.temporaryDirectory
      .appendingPathComponent("mountmate-fstab-expected-\(UUID().uuidString)")

    if !normalizedContents.isEmpty {
      try normalizedContents.write(to: temporaryURL, atomically: true, encoding: .utf8)
    }
    try expectedCurrent.write(to: expectedURL, options: .atomic)

    defer {
      try? fileManager.removeItem(at: temporaryURL)
      try? fileManager.removeItem(at: expectedURL)
    }

    // A missing /etc/fstab matches an empty expected file.
    let expectedPath = expectedURL.path.shellQuoted
    let guardCommand =
      "if [ -e /etc/fstab ]; then /usr/bin/cmp -s \(expectedPath) /etc/fstab; else [ ! -s \(expectedPath) ]; fi || { echo \(Self.fstabChangedMarker) >&2; exit 1; }"

    let writeCommand: String
    if normalizedContents.isEmpty {
      writeCommand = "/bin/rm -f /etc/fstab"
    } else {
      // Do not use `install` here. On recent macOS versions it stages the
      // destination in /etc and atomically replaces /etc/fstab with rename(2),
      // which can be rejected even after administrator authentication. Writing
      // the existing file in place avoids that protected-directory rename.
      writeCommand =
        "/bin/cat \(temporaryURL.path.shellQuoted) > /etc/fstab && /bin/chmod 644 /etc/fstab && /usr/sbin/chown root:wheel /etc/fstab"
    }
    let command = "\(guardCommand); \(writeCommand)"

    let prompt = NSLocalizedString(
      "System Mount Rule Admin Prompt", comment: "Administrator password prompt for /etc/fstab")
    let script =
      "do shell script \(command.appleScriptStringLiteral) with prompt \(prompt.appleScriptStringLiteral) with administrator privileges"
    let result = runProcess(
      executable: "/usr/bin/osascript",
      arguments: ["-e", script],
      timeout: 300)
    if !result.succeeded && result.stderr.contains(Self.fstabChangedMarker) {
      throw NSError(
        domain: "MountMate",
        code: Self.fstabChangedErrorCode,
        userInfo: [
          NSLocalizedDescriptionKey:
            "/etc/fstab was changed by another process during the update. Please try again."
        ])
    }
    if !result.succeeded {
      let error =
        result.stderr.isEmpty
        ? NSLocalizedString(
          "Custom Mount Point System Error",
          comment: "Fallback custom mount point system configuration error")
        : result.stderr
      throw NSError(
        domain: "MountMate",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: error])
    }
  }

  private func managedFstabComment(for volume: Volume) -> String {
    "\(Self.mountMateFstabPrefix) \(stableIdentifier(for: volume))"
  }

  private func isConflictingFstabEntry(_ line: String, volumeUUID: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
    let uuidPrefix = "UUID=\(volumeUUID)"
    guard trimmed.hasPrefix(uuidPrefix), trimmed.count > uuidPrefix.count else { return false }
    let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: uuidPrefix.count)
    return trimmed[separatorIndex].isWhitespace
  }

  private func fstabEscapedField(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: " ", with: "\\040")
      .replacingOccurrences(of: "\t", with: "\\011")
  }

  static func trimmedFstabContents(_ contents: String) -> String {
    let lines = contents.components(separatedBy: .newlines)
    var end = lines.count
    while end > 0 && lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
      end -= 1
    }

    guard end > 0 else { return "" }
    return lines[..<end].joined(separator: "\n") + "\n"
  }

  // MARK: - Private Save/Load Helpers

  private func save<T: Codable>(_ items: [T], to key: String) {
    if let data = try? JSONEncoder().encode(items) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
  private static func load<T: Codable>(from key: String) -> [T] {
    if let data = UserDefaults.standard.data(forKey: key) {
      return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
    return []
  }

  private func saveProtectedVolumes() { save(protectedVolumes, to: protectedVolumesKey) }
  private func saveIgnoredVolumes() { save(ignoredVolumes, to: ignoredVolumesKey) }
  private func saveBlockedVolumes() { save(blockedVolumes, to: blockedVolumesKey) }
  private func saveKeepAliveVolumes() { save(keepAliveVolumes, to: keepAliveVolumesKey) }
  private func saveNetworkShares() { save(networkShares, to: networkSharesKey) }
  private func saveCustomMountPoints() { save(customMountPoints, to: customMountPointsKey) }

}
