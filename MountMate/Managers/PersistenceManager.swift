//  Created by homielab.com

import Combine
import Foundation

class PersistenceManager: ObservableObject {
  static let shared = PersistenceManager()

  private static let pinnedVolumeIDsKey = "pinnedVolumeIDs"
  private static let blockAtStartupKey = "blockAtStartup"

  /// Where every list and setting is stored. Tests pass a temporary suite.
  private let defaults: UserDefaults

  private let protectedVolumesKey = "mountmate_protectedVolumes_v4"
  private let ignoredVolumesKey = "mountmate_ignoredVolumes_v4"
  private let blockedVolumesKey = "mountmate_blockedVolumes_v1"
  private let keepAliveVolumesKey = "mountmate_keepAliveVolumes_v1"
  private let networkSharesKey = "mountmate_networkShares_v1"
  private let customMountPointsKey = "mountmate_customMountPoints_v1"
  private let idleUnmountVolumesKey = "mountmate_idleUnmountVolumes_v1"

  @Published var protectedVolumes: [ManagedVolumeInfo]
  @Published var ignoredVolumes: [ManagedVolumeInfo]
  @Published var blockedVolumes: [ManagedVolumeInfo]
  @Published var keepAliveVolumes: [ManagedVolumeInfo]
  @Published var networkShares: [NetworkShare]
  @Published var customMountPoints: [VolumeCustomMountPoint]
  /// Volumes unmounted after some minutes without disk activity. Only
  /// entries with `minutes > 0` are stored.
  @Published var idleUnmountVolumes: [IdleUnmountVolume]
  /// Volumes pinned to the top of the menu bar list, in the order they were
  /// pinned. Stored by composite ID so pins survive reconnecting the drive.
  @Published var pinnedVolumeIDs: [String] {
    didSet { defaults.set(pinnedVolumeIDs, forKey: Self.pinnedVolumeIDsKey) }
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

  /// Removes a pin by its stored composite ID, e.g. from Settings for a
  /// volume that is not connected.
  func unpin(id: String) {
    pinnedVolumeIDs.removeAll { $0 == id }
  }

  /// When on, every blocked volume also gets a `noauto` rule in /etc/fstab,
  /// so macOS itself skips mounting it at startup — before MountMate (or any
  /// login item) is running. Off by default because each change to
  /// /etc/fstab needs the administrator password.
  @Published private(set) var blockAtStartup: Bool

  /// True while a user-initiated startup-rule update is running (including
  /// while the password prompt is up). Shown as a spinner in Settings.
  @Published private(set) var isUpdatingStartupRules = false
  /// Number of MountMate startup-block rules currently in /etc/fstab.
  @Published private(set) var startupRuleCount = 0

  /// Volume UUIDs (uppercased) that currently have a MountMate startup-block
  /// rule in /etc/fstab. Main thread only. Not @Published: no view shows it,
  /// and publishing would redraw every observer of this manager.
  private(set) var fstabBlockedVolumeUUIDs: Set<String> = []

  /// diskutil lookups for new rules. Only used in fstab jobs (`startupBlock.enqueueFstabJob`), one at a time.
  let volumeLookup: FstabVolumeLookup
  /// Keeps /etc/fstab in step with `blockedVolumes` (see the type's notes).
  /// Its queue also serializes custom mount point updates.
  lazy var startupBlock = StartupBlockCoordinator(
    defaults: defaults, access: fstabAccess, host: self)
  private let fstabAccess: StartupBlockFstabAccess

  /// - Parameters:
  ///   - defaults: Where lists and settings are stored.
  ///   - fstabAccess: /etc/fstab and `diskutil` access for the startup-block
  ///     rules; defaults to the real system.
  init(defaults: UserDefaults = .standard, fstabAccess: StartupBlockFstabAccess? = nil) {
    let volumeLookup = FstabVolumeLookup()
    let fstabAccess = fstabAccess ?? SystemFstabAccess(lookup: volumeLookup)
    self.defaults = defaults
    self.volumeLookup = volumeLookup
    self.fstabAccess = fstabAccess
    self.blockAtStartup = defaults.bool(forKey: Self.blockAtStartupKey)
    self.protectedVolumes = Self.droppingNonUUIDEntries(
      CodableDefaultsStore.load(from: protectedVolumesKey, defaults: defaults))
    self.ignoredVolumes = Self.migratedIgnoredEntries(
      CodableDefaultsStore.load(from: ignoredVolumesKey, defaults: defaults))
    self.blockedVolumes = Self.droppingNonUUIDEntries(
      CodableDefaultsStore.load(from: blockedVolumesKey, defaults: defaults))
    self.keepAliveVolumes = Self.droppingNonUUIDEntries(
      CodableDefaultsStore.load(from: keepAliveVolumesKey, defaults: defaults))
    self.networkShares = CodableDefaultsStore.load(from: networkSharesKey, defaults: defaults)
    self.customMountPoints = CodableDefaultsStore.load(
      from: customMountPointsKey, defaults: defaults)
    self.idleUnmountVolumes = CodableDefaultsStore.load(
      from: idleUnmountVolumesKey, defaults: defaults
    ).filter {
      (entry: IdleUnmountVolume) in
      entry.minutes > 0 && Self.normalizedSystemVolumeUUID(entry.volumeUUID) != nil
    }
    self.fstabBlockedVolumeUUIDs = FstabRules.managedFstabVolumeUUIDs(
      kinds: [FstabRules.mountMateBlockPrefix], in: fstabAccess.readContents())
    // Same for pins ("<diskUUID or NONE>-<volume UUID>"). Property observers
    // do not run in init, so this only takes effect with the next pin change.
    self.pinnedVolumeIDs = (defaults.stringArray(forKey: Self.pinnedVolumeIDsKey) ?? []).filter {
      Self.normalizedSystemVolumeUUID(String($0.suffix(36))) != nil
    }
  }

  /// Volumes without a volume UUID used to be saved under their BSD device
  /// name (e.g. "NONE-disk4s1"), so whichever volume later got that device
  /// name inherited the setting. `Volume.compositeId` is now nil for such
  /// volumes, so these entries can never match again; drop them on load.
  /// They disappear from storage with the next save of the list.
  private static func droppingNonUUIDEntries(_ infos: [ManagedVolumeInfo]) -> [ManagedVolumeInfo] {
    infos.filter { normalizedSystemVolumeUUID($0.volumeUUID) != nil }
  }

  /// The ignore list may keep partitions without a volume UUID, keyed by
  /// their partition DiskUUID (see `Volume.ignoreIdentifier`). Old entries
  /// "<partition DiskUUID>-diskXsY" are moved to "<DiskUUID>-<DiskUUID>";
  /// entries with neither UUID ("NONE-diskXsY") are dropped. Idempotent, and
  /// stored with the next save of the list.
  static func migratedIgnoredEntries(_ infos: [ManagedVolumeInfo]) -> [ManagedVolumeInfo] {
    var seen = Set<String>()
    return infos.compactMap { info -> ManagedVolumeInfo? in
      if normalizedSystemVolumeUUID(info.volumeUUID) != nil { return info }
      guard let partitionUUID = Volume.partitionIgnoreUUID(info.diskUUID) else { return nil }
      return ManagedVolumeInfo(volumeUUID: partitionUUID, diskUUID: partitionUUID, name: info.name)
    }
    .filter { seen.insert($0.id).inserted }
  }

  // MARK: - Names

  /// Entries whose volume is present under a different name, with the new
  /// name; nil when nothing changed (so callers neither assign nor save).
  /// Matches by id; entries of absent volumes keep their last-known name.
  static func renamed(
    _ entries: [ManagedVolumeInfo], using volumes: [Volume],
    key: (Volume) -> String? = { $0.managedVolumeInfo?.id }
  ) -> [ManagedVolumeInfo]? {
    let names = currentNames(of: volumes, key: key)
    var changed = false
    let result = entries.map { entry -> ManagedVolumeInfo in
      guard let name = names[entry.id], name != entry.name else { return entry }
      changed = true
      var copy = entry
      copy.name = name
      return copy
    }
    return changed ? result : nil
  }

  static func renamed(_ entries: [IdleUnmountVolume], using volumes: [Volume])
    -> [IdleUnmountVolume]?
  {
    let names = currentNames(of: volumes, key: { $0.managedVolumeInfo?.id })
    var changed = false
    let result = entries.map { entry -> IdleUnmountVolume in
      guard let name = names[entry.id], name != entry.name else { return entry }
      changed = true
      var copy = entry
      copy.name = name
      return copy
    }
    return changed ? result : nil
  }

  static func renamed(_ entries: [VolumeCustomMountPoint], using volumes: [Volume])
    -> [VolumeCustomMountPoint]?
  {
    let names = currentNames(
      of: volumes,
      key: { volume in
        volume.stableVolumeUUID.map { "\(volume.diskUUID ?? volume.deviceIdentifier)-\($0)" }
      })
    var changed = false
    let result = entries.map { entry -> VolumeCustomMountPoint in
      guard let name = names[entry.id], name != entry.name else { return entry }
      changed = true
      var copy = entry
      copy.name = name
      return copy
    }
    return changed ? result : nil
  }

  private static func currentNames(of volumes: [Volume], key: (Volume) -> String?) -> [String:
    String]
  {
    var names: [String: String] = [:]
    for volume in volumes {
      if let id = key(volume) { names[id] = volume.name }
    }
    return names
  }

  /// Brings the saved names up to date after a successful refresh (Rename
  /// Volume, a rename in Finder). Saves only the lists that changed.
  /// Main thread only.
  func refreshNames(from volumes: [Volume]) {
    if let list = Self.renamed(protectedVolumes, using: volumes) {
      protectedVolumes = list
      saveProtectedVolumes()
    }
    if let list = Self.renamed(blockedVolumes, using: volumes) {
      blockedVolumes = list
      saveBlockedVolumes()
    }
    if let list = Self.renamed(keepAliveVolumes, using: volumes) {
      keepAliveVolumes = list
      saveKeepAliveVolumes()
    }
    if let list = Self.renamed(ignoredVolumes, using: volumes, key: { $0.ignoreIdentifier }) {
      ignoredVolumes = list
      saveIgnoredVolumes()
    }
    if let list = Self.renamed(idleUnmountVolumes, using: volumes) {
      idleUnmountVolumes = list
      saveIdleUnmountVolumes()
    }
    if let list = Self.renamed(customMountPoints, using: volumes) {
      customMountPoints = list
      saveCustomMountPoints()
    }
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
    guard let info = volume.ignoreVolumeInfo else { return false }
    guard !ignoredVolumes.contains(where: { $0.id == info.id }) else { return true }
    ignoredVolumes.append(info)
    saveIgnoredVolumes()
    return true
  }

  func ignore(disk: PhysicalDisk) {
    // Same identity scheme as ignoring a single volume.
    let infos = disk.allVolumes.compactMap(\.ignoreVolumeInfo)

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
      startupBlock.reconcile(userInitiated: true)
    }
    return true
  }

  func unblock(info: ManagedVolumeInfo) {
    blockedVolumes.removeAll { $0.id == info.id }
    saveBlockedVolumes()

    // Remove the volume's startup rule even when the setting is off, so an
    // unblocked volume never stays blocked at boot. While the setting is on,
    // always reconcile: a rule for this volume may still be in flight on
    // in a queued fstab job (block then unblock during the password prompt) and not yet
    // reflected in fstabBlockedVolumeUUIDs. The queued reconcile runs after
    // it and removes the rule; when nothing changes it does not prompt.
    let hasKnownRule =
      Self.normalizedSystemVolumeUUID(info.volumeUUID)
      .map { fstabBlockedVolumeUUIDs.contains($0) } ?? false
    if blockAtStartup || hasKnownRule {
      startupBlock.reconcile(userInitiated: true)
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

  /// Choices offered for "Unmount When Idle", in minutes (0 = off).
  static let idleUnmountChoices = [0, 1, 5, 15, 30, 60]

  /// Minutes of inactivity after which `volume` is unmounted; 0 = off.
  func idleUnmountMinutes(for volume: Volume) -> Int {
    guard let compositeId = volume.compositeId else { return 0 }
    return idleUnmountVolumes.first { $0.id == compositeId }?.minutes ?? 0
  }

  /// Sets or (with 0) clears the idle timeout. False when the volume has no
  /// UUID to save the setting under.
  @discardableResult
  func setIdleUnmountMinutes(_ minutes: Int, volume: Volume) -> Bool {
    guard let info = volume.managedVolumeInfo else { return false }
    idleUnmountVolumes.removeAll { $0.id == info.id }
    if minutes > 0 {
      idleUnmountVolumes.append(IdleUnmountVolume(info: info, minutes: minutes))
    }
    saveIdleUnmountVolumes()
    return true
  }

  func removeIdleUnmount(info: IdleUnmountVolume) {
    idleUnmountVolumes.removeAll { $0.id == info.id }
    saveIdleUnmountVolumes()
  }

  func addNetworkShare(_ share: NetworkShare) {
    networkShares.append(share)
    saveNetworkShares()
  }

  /// Adds discovered shares without creating duplicate entries for the same SMB endpoint.
  @discardableResult
  func addNetworkSharesIfNeeded(_ shares: [NetworkShare]) -> Int {
    var addedCount = 0

    for var share in shares where !containsNetworkShare(matching: share) {
      // The default mount folder is ~/mountmate/<name>, so two imported shares
      // with the same name (e.g. "public" on two servers) would collide.
      share.name = Self.uniqueShareName(
        share.name, existing: networkShares.map(\.name))
      networkShares.append(share)
      addedCount += 1
    }

    if addedCount > 0 {
      saveNetworkShares()
    }
    return addedCount
  }

  /// `name`, or "name (2)", "name (3)"… — the first one not already used
  /// (case-insensitively) by `existing`.
  static func uniqueShareName(_ name: String, existing: [String]) -> String {
    let taken = Set(existing.map { $0.lowercased() })
    guard taken.contains(name.lowercased()) else { return name }
    var index = 2
    while taken.contains("\(name) (\(index))".lowercased()) { index += 1 }
    return "\(name) (\(index))"
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

  // MARK: - Volume Helpers

  /// Normalizes a volume identifier into an uppercased UUID string, or nil
  /// when the identifier is not a UUID (e.g. a fallback device name such as
  /// "disk4s2"), which cannot address a volume reliably across reboots.
  static func normalizedSystemVolumeUUID(_ raw: String) -> String? {
    guard let uuid = UUID(uuidString: raw) else { return nil }
    return uuid.uuidString
  }

  // MARK: - Startup Blocking (/etc/fstab)

  /// Turns startup blocking on or off and syncs /etc/fstab right away (one
  /// administrator prompt, or none when there is nothing to change). If the
  /// update fails, the setting goes back to its previous value.
  func setBlockAtStartup(_ enabled: Bool) {
    guard enabled != blockAtStartup else { return }
    let previous = blockAtStartup
    blockAtStartup = enabled
    defaults.set(enabled, forKey: Self.blockAtStartupKey)

    // Cancelling the password prompt here just turns the toggle back, with
    // no alert: the user saw the toggle and chose not to continue.
    startupBlock.reconcile(userInitiated: true, silentOnCancel: true, fromToggle: true) {
      [weak self] succeeded in
      // Only roll back if the user has not changed the setting again since.
      guard let self, !succeeded, self.blockAtStartup == enabled else { return }
      self.blockAtStartup = previous
      self.defaults.set(previous, forKey: Self.blockAtStartupKey)
    }
  }

  func reconcileStartupBlockRulesAtLaunch() {
    startupBlock.reconcileAtLaunch(
      enabled: blockAtStartup, knownRuleUUIDs: fstabBlockedVolumeUUIDs)
  }

  func scheduleStartupBlockReconcile() { startupBlock.scheduleReconcile() }

  // MARK: - Helper Checkers

  func isVolumeProtected(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return protectedVolumes.contains { $0.id == compositeId }
  }

  func isVolumeIgnored(_ volume: Volume) -> Bool {
    guard let ignoreID = volume.ignoreIdentifier else { return false }
    return ignoredVolumes.contains { $0.id == ignoreID }
  }

  func isVolumeBlocked(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return blockedVolumes.contains { $0.id == compositeId }
  }

  func stableIdentifier(for volume: Volume) -> String {
    "\(backingDiskIdentifier(for: volume))-\(volume.id)"
  }

  func backingDiskIdentifier(for volume: Volume) -> String {
    volume.diskUUID ?? volume.deviceIdentifier
  }

  func volumeUUIDForSystemMount(for volume: Volume) -> String? {
    volume.stableVolumeUUID
  }

  private func save<T: Codable>(_ items: [T], to key: String) {
    CodableDefaultsStore.save(items, to: key, defaults: defaults)
  }

  private func saveProtectedVolumes() { save(protectedVolumes, to: protectedVolumesKey) }
  private func saveIgnoredVolumes() { save(ignoredVolumes, to: ignoredVolumesKey) }
  private func saveBlockedVolumes() { save(blockedVolumes, to: blockedVolumesKey) }
  private func saveKeepAliveVolumes() { save(keepAliveVolumes, to: keepAliveVolumesKey) }
  private func saveNetworkShares() { save(networkShares, to: networkSharesKey) }
  func saveCustomMountPoints() { save(customMountPoints, to: customMountPointsKey) }
  private func saveIdleUnmountVolumes() { save(idleUnmountVolumes, to: idleUnmountVolumesKey) }
}

extension PersistenceManager: StartupBlockHost {
  func startupBlockState() -> (enabled: Bool, blockedInfos: [ManagedVolumeInfo]) {
    (blockAtStartup, blockedVolumes)
  }

  func startupBlockUpdateInProgress(_ inProgress: Bool) {
    isUpdatingStartupRules = inProgress
  }

  func startupBlockRulesDidChange(volumeUUIDs: Set<String>) {
    fstabBlockedVolumeUUIDs = volumeUUIDs
    if startupRuleCount != volumeUUIDs.count { startupRuleCount = volumeUUIDs.count }
  }

  func startupBlockShowFeedback(_ message: String) {
    FeedbackHUD.show(message)
  }

  func startupBlockDidFail(title: String, message: String) {
    DriveManager.shared.userActionError = AppAlert(title: title, message: message, kind: .basic)
  }
}
