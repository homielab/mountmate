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

  /// Removes a pin by its stored composite ID, e.g. from Settings for a
  /// volume that is not connected.
  func unpin(id: String) {
    pinnedVolumeIDs.removeAll { $0 == id }
  }

  /// When on, every blocked volume also gets a `noauto` rule in /etc/fstab,
  /// so macOS itself skips mounting it at startup — before MountMate (or any
  /// login item) is running. Off by default because each change to
  /// /etc/fstab needs the administrator password.
  @Published private(set) var blockAtStartup: Bool = UserDefaults.standard.bool(
    forKey: "blockAtStartup")

  /// True while a user-initiated startup-rule update is running (including
  /// while the password prompt is up). Shown as a spinner in Settings.
  @Published private(set) var isUpdatingStartupRules = false
  /// Number of MountMate startup-block rules currently in /etc/fstab.
  @Published private(set) var startupRuleCount = 0

  /// Volume UUIDs (uppercased) that currently have a MountMate startup-block
  /// rule in /etc/fstab. Main thread only. Not @Published: no view shows it,
  /// and publishing would redraw every observer of this manager.
  private(set) var fstabBlockedVolumeUUIDs: Set<String> = []

  /// Serializes every startup-block read-modify-write cycle of /etc/fstab so
  /// concurrent block, unblock and reconcile actions cannot interleave.
  private let fstabQueue = DispatchQueue(label: "com.homielab.mountmate.fstab")
  /// diskutil lookups for new rules. Only used on `fstabQueue`.
  private let volumeLookup = FstabVolumeLookup()
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
    self.protectedVolumes = Self.droppingNonUUIDEntries(
      CodableDefaultsStore.load(from: protectedVolumesKey))
    self.ignoredVolumes = Self.migratedIgnoredEntries(
      CodableDefaultsStore.load(from: ignoredVolumesKey))
    self.blockedVolumes = Self.droppingNonUUIDEntries(
      CodableDefaultsStore.load(from: blockedVolumesKey))
    self.keepAliveVolumes = Self.droppingNonUUIDEntries(
      CodableDefaultsStore.load(from: keepAliveVolumesKey))
    self.networkShares = CodableDefaultsStore.load(from: networkSharesKey)
    self.customMountPoints = CodableDefaultsStore.load(from: customMountPointsKey)
    self.idleUnmountVolumes = CodableDefaultsStore.load(from: idleUnmountVolumesKey).filter {
      (entry: IdleUnmountVolume) in
      entry.minutes > 0 && Self.normalizedSystemVolumeUUID(entry.volumeUUID) != nil
    }
    self.fstabBlockedVolumeUUIDs = FstabRules.managedFstabVolumeUUIDs(
      kinds: [FstabRules.mountMateBlockPrefix], in: FstabWriter.readSystemFstabContents())
    // Same for pins ("<diskUUID or NONE>-<volume UUID>"). Property observers
    // do not run in init, so this only takes effect with the next pin change.
    self.pinnedVolumeIDs = pinnedVolumeIDs.filter {
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
    let hasKnownRule =
      Self.normalizedSystemVolumeUUID(info.volumeUUID)
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

  func customMountPoint(for volume: Volume) -> VolumeCustomMountPoint? {
    // Custom mount points are /etc/fstab rules addressed by volume UUID, so
    // only volumes with a real UUID can have one.
    guard volume.stableVolumeUUID != nil else { return nil }
    let identifier = stableIdentifier(for: volume)
    return customMountPoints.first { $0.id == identifier }
  }

  /// Outcome of an asynchronous custom mount point update.
  enum CustomMountPointUpdateResult: Equatable {
    case success
    /// The user dismissed the administrator password prompt; nothing changed.
    case cancelled
    /// A localized message to show to the user.
    case failure(String)
  }

  /// Adds or replaces the volume's custom mount point: writes its /etc/fstab
  /// rule (which may show the administrator password prompt), then saves it
  /// in MountMate's list.
  ///
  /// The `diskutil` lookup and the privileged write run on `fstabQueue`, so
  /// the UI never waits for the password prompt, and the update is
  /// serialized with startup-block reconciles. Call on the main thread;
  /// `completion` is called on the main thread.
  func applyCustomMountPoint(
    _ mountPoint: String, for volume: Volume,
    completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    guard !isVolumeBlocked(volume) else {
      completion(
        .failure(
          NSLocalizedString(
            "Custom Mount Point Volume Blocked",
            comment: "Custom mount point blocked-volume error")))
      return
    }
    guard let volumeUUID = volumeUUIDForSystemMount(for: volume) else {
      completion(
        .failure(
          NSLocalizedString(
            "Custom Mount Point Requires UUID",
            comment: "Custom mount point system configuration error")))
      return
    }

    fstabQueue.async {
      guard let fileSystemType = self.volumeLookup.fstabFileSystemType(for: volume) else {
        DispatchQueue.main.async {
          completion(
            .failure(
              NSLocalizedString(
                "Custom Mount Point Unsupported File System",
                comment: "Custom mount point system configuration error")))
        }
        return
      }

      do {
        let snapshot = try FstabWriter.loadSnapshot()
        let currentContents = snapshot.contents
        let updatedContents = try FstabRules.updatedFstabContents(
          from: currentContents,
          volumeUUID: volumeUUID,
          identifier: self.stableIdentifier(for: volume),
          mountPoint: mountPoint,
          fileSystemType: fileSystemType
        )

        // The volume may have been blocked while this job waited in the
        // queue (e.g. behind another password prompt). Read the current
        // state, as reconcile does. (Safe: main never waits on fstabQueue.)
        let isBlockedNow = DispatchQueue.main.sync { self.isVolumeBlocked(volume) }
        guard !isBlockedNow else {
          DispatchQueue.main.async {
            completion(
              .failure(
                NSLocalizedString(
                  "Custom Mount Point Volume Blocked",
                  comment: "Custom mount point blocked-volume error")))
          }
          return
        }

        if updatedContents != currentContents {
          try FstabWriter.install(updatedContents, expectedCurrent: snapshot.raw)
        }

        DispatchQueue.main.async {
          self.saveCustomMountPoint(mountPoint, for: volume)
          completion(.success)
        }
      } catch {
        let result = Self.customMountPointUpdateResult(for: error)
        DispatchQueue.main.async { completion(result) }
      }
    }
  }

  /// Removes the volume's custom mount point: its /etc/fstab rule (which
  /// may show the administrator password prompt) and its saved entry. Runs
  /// like `applyCustomMountPoint`. Call on the main thread; `completion` is
  /// called on the main thread.
  func removeCustomMountPoint(
    for volume: Volume, completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    removeCustomMountPoint(
      volumeUUID: volumeUUIDForSystemMount(for: volume),
      entryID: stableIdentifier(for: volume),
      completion: completion)
  }

  /// Same as `removeCustomMountPoint(for:completion:)`, from the saved entry
  /// alone, so entries of volumes that are not connected can be removed too.
  func removeCustomMountPoint(
    info: VolumeCustomMountPoint, completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    removeCustomMountPoint(
      volumeUUID: Self.normalizedSystemVolumeUUID(info.volumeUUID) != nil ? info.volumeUUID : nil,
      entryID: info.id,
      completion: completion)
  }

  /// - Parameters:
  ///   - volumeUUID: The UUID the /etc/fstab rule addresses, or nil when the
  ///     volume has none (then it cannot have a rule, and only the saved
  ///     entry is removed).
  ///   - entryID: The `VolumeCustomMountPoint.id` of the saved entry.
  private func removeCustomMountPoint(
    volumeUUID: String?, entryID: String,
    completion: @escaping (CustomMountPointUpdateResult) -> Void
  ) {
    fstabQueue.async {
      do {
        if let volumeUUID {
          let snapshot = try FstabWriter.loadSnapshot()
          let currentContents = snapshot.contents
          let updatedContents = FstabRules.removingCustomMountEntry(
            volumeUUID: volumeUUID, from: currentContents)

          if updatedContents != currentContents {
            try FstabWriter.install(updatedContents, expectedCurrent: snapshot.raw)
          }
        }

        DispatchQueue.main.async {
          self.customMountPoints.removeAll { $0.id == entryID }
          self.saveCustomMountPoints()
          completion(.success)
        }
      } catch {
        let result = Self.customMountPointUpdateResult(for: error)
        DispatchQueue.main.async { completion(result) }
      }
    }
  }

  private static func customMountPointUpdateResult(for error: Error)
    -> CustomMountPointUpdateResult
  {
    if FstabWriter.isAdminPromptCancellation(error) { return .cancelled }
    return .failure(
      String(
        format: NSLocalizedString(
          "Custom Mount Point System Save Error",
          comment: "Custom mount point system configuration error"),
        error.localizedDescription))
  }

  /// Main thread only.
  private func saveCustomMountPoint(_ mountPoint: String, for volume: Volume) {
    let identifier = stableIdentifier(for: volume)
    let info = VolumeCustomMountPoint(
      volumeUUID: volume.id,
      backingDiskIdentifier: backingDiskIdentifier(for: volume),
      name: volume.name,
      mountPoint: mountPoint
    )

    if let index = customMountPoints.firstIndex(where: { $0.id == identifier }) {
      customMountPoints[index] = info
    } else {
      customMountPoints.append(info)
    }
    saveCustomMountPoints()
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

    // Cancelling the password prompt here just turns the toggle back, with
    // no alert: the user saw the toggle and chose not to continue.
    reconcileStartupBlockRules(userInitiated: true, silentOnCancel: true, fromToggle: true) {
      [weak self] succeeded in
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
  ///   - silentOnCancel: Show no alert when the user cancels the
  ///     administrator prompt (the caller reports the failure itself).
  ///   - completion: Called on the main thread with false if the update failed.
  func reconcileStartupBlockRules(
    userInitiated: Bool, silentOnCancel: Bool = false, fromToggle: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    if userInitiated { isUpdatingStartupRules = true }
    fstabQueue.async { [weak self] in
      guard let self else { return }
      defer {
        if userInitiated {
          DispatchQueue.main.async { self.isUpdatingStartupRules = false }
        }
      }
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
        let change = try self.applyStartupBlockRules(
          enabled: enabled, blockedInfos: blockedInfos, attemptsLeft: 2)
        if userInitiated,
          let message = FstabRules.feedbackMessage(
            for: change, enabled: enabled, fromToggle: fromToggle)
        {
          FeedbackHUD.show(message)
        }
        DispatchQueue.main.async { completion?(true) }
      } catch {
        if userInitiated {
          if !(silentOnCancel && FstabWriter.isAdminPromptCancellation(error)) {
            self.handleStartupBlockError(error)
          }
        } else {
          // No alert for updates the user did not just ask for.
          self.backgroundFstabUpdateDeclined = true
          Log.persistence.error(
            "Background startup block update failed; not retrying until the next user action: \(error.localizedDescription, privacy: .public)"
          )
        }
        DispatchQueue.main.async { completion?(false) }
      }
    }
  }

  /// One read-compute-write cycle of `reconcileStartupBlockRules`. Runs on
  /// `fstabQueue`. Retries when /etc/fstab changed between the read and the
  /// privileged write (e.g. a custom mount point was saved meanwhile).
  @discardableResult
  private func applyStartupBlockRules(
    enabled: Bool, blockedInfos: [ManagedVolumeInfo], attemptsLeft: Int
  ) throws -> FstabRules.StartupRuleChange {
    do {
      let snapshot = try FstabWriter.loadSnapshot()
      let contents = snapshot.contents
      let diff = FstabRules.startupBlockDiff(
        enabled: enabled, blockedInfos: blockedInfos, contents: contents)

      for info in diff.alreadyHasEntry {
        Log.persistence.info(
          "“\(info.name, privacy: .private)” already has an /etc/fstab entry; not adding a startup block rule."
        )
      }
      var additions: [FstabRules.StartupBlockAddition] = []
      for (uuid, info) in diff.missing {
        switch self.volumeLookup.startupBlockEligibility(forVolumeUUID: uuid) {
        case .eligible(let fileSystemType):
          additions.append(.init(uuid: uuid, fileSystemType: fileSystemType, info: info))
        case .notConnected:
          Log.persistence.info(
            "“\(info.name, privacy: .private)” is not connected; its startup block rule will be added when it next appears."
          )
        case .ineligible(let reason):
          Log.persistence.info(
            "No startup block rule for “\(info.name, privacy: .private)”: \(reason, privacy: .public)."
          )
        }
      }

      let stale = diff.stale
      guard !stale.isEmpty || !additions.isEmpty else {
        self.refreshFstabBlockedUUIDs(from: contents)
        return FstabRules.StartupRuleChange(ruleCount: diff.present.count)
      }

      let (updated, skipped) = FstabRules.applyingStartupBlockChanges(
        to: contents, removing: stale, adding: additions)
      for addition in skipped {
        Log.persistence.error(
          "Skipped a startup block rule with unsafe fields (“\(addition.info.name, privacy: .private)”)."
        )
      }

      try FstabWriter.install(updated, expectedCurrent: snapshot.raw)
      self.refreshFstabBlockedUUIDs(from: updated)
      Log.persistence.notice(
        "Startup block rules updated (\(additions.count, privacy: .public) added, \(stale.count, privacy: .public) removed)."
      )
      return FstabRules.StartupRuleChange(
        addedNames: additions.map(\.info.name), removedCount: stale.count,
        ruleCount: diff.present.count - stale.count + additions.count)
    } catch let error as NSError
      where error.domain == "MountMate" && error.code == FstabWriter.fstabChangedErrorCode
      && attemptsLeft > 1
    {
      Log.persistence.notice(
        "/etc/fstab changed during the update; retrying with the new contents.")
      return try applyStartupBlockRules(
        enabled: enabled, blockedInfos: blockedInfos, attemptsLeft: attemptsLeft - 1)
    }
  }

  private func refreshFstabBlockedUUIDs(from contents: String) {
    let uuids = FstabRules.managedFstabVolumeUUIDs(
      kinds: [FstabRules.mountMateBlockPrefix], in: contents)
    DispatchQueue.main.async { [weak self] in
      self?.fstabBlockedVolumeUUIDs = uuids
      if self?.startupRuleCount != uuids.count { self?.startupRuleCount = uuids.count }
    }
  }

  private func handleStartupBlockError(_ error: Error) {
    Log.persistence.error(
      "Failed to update startup block rules in /etc/fstab: \(error.localizedDescription, privacy: .public)"
    )
    // A cancelled password prompt is not an error; say plainly what it means.
    let message =
      FstabWriter.isAdminPromptCancellation(error)
      ? NSLocalizedString(
        "System Mount Rule Update Cancelled",
        comment: "Alert message when the admin prompt for a startup block rule was cancelled")
      : String(
        format: NSLocalizedString(
          "System Mount Rule Update Failed", comment: "Alert message"),
        error.localizedDescription)
    DispatchQueue.main.async {
      DriveManager.shared.userActionError = AppAlert(
        title: NSLocalizedString("System Mount Rule Not Updated", comment: "Alert title"),
        message: message,
        kind: .basic)
    }
  }

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

  private func stableIdentifier(for volume: Volume) -> String {
    "\(backingDiskIdentifier(for: volume))-\(volume.id)"
  }

  private func backingDiskIdentifier(for volume: Volume) -> String {
    volume.diskUUID ?? volume.deviceIdentifier
  }

  private func volumeUUIDForSystemMount(for volume: Volume) -> String? {
    volume.stableVolumeUUID
  }

  private func save<T: Codable>(_ items: [T], to key: String) {
    CodableDefaultsStore.save(items, to: key)
  }

  private func saveProtectedVolumes() { save(protectedVolumes, to: protectedVolumesKey) }
  private func saveIgnoredVolumes() { save(ignoredVolumes, to: ignoredVolumesKey) }
  private func saveBlockedVolumes() { save(blockedVolumes, to: blockedVolumesKey) }
  private func saveKeepAliveVolumes() { save(keepAliveVolumes, to: keepAliveVolumesKey) }
  private func saveNetworkShares() { save(networkShares, to: networkSharesKey) }
  private func saveCustomMountPoints() { save(customMountPoints, to: customMountPointsKey) }
  private func saveIdleUnmountVolumes() { save(idleUnmountVolumes, to: idleUnmountVolumesKey) }
}
