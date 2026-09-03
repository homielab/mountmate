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

  /// Volume UUIDs (uppercased) that currently have a boot-time "noauto" rule
  /// in /etc/fstab. While the rule is in place, diskarbitrationd never
  /// attempts the auto-mount itself, so any mount request that still reaches
  /// the DiskArbitration approval callback is a deliberate manual mount.
  @Published private(set) var fstabBlockedVolumeUUIDs: Set<String> = []

  static let mountMateFstabPrefix = "# MountMate custom mount:"
  static let mountMateBlockPrefix = "# MountMate block:"

  /// Serializes every /etc/fstab read-modify-write cycle so concurrent block,
  /// unblock and reconcile actions cannot interleave their installs.
  private let fstabQueue = DispatchQueue(label: "com.homielab.mountmate.fstab")
  private var isFstabReconcilePending = false
  /// Set when a scheduled fstab update fails (e.g. the admin prompt is
  /// cancelled) so background reconciles stop re-prompting until the next
  /// explicit user action or app launch.
  private var fstabAdminDeclinedThisSession = false

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
    installBlockedFstabEntry(for: volume, info: info)
    return true
  }

  func unblock(info: ManagedVolumeInfo) {
    blockedVolumes.removeAll { $0.id == info.id }
    saveBlockedVolumes()
    removeBlockedFstabEntry(for: info)
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
    let path = share.sharePath
      .removingPercentEncoding?
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
      ?? share.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()

    return networkShares.contains { existing in
      let existingServer = existing.server
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let existingPath = existing.sharePath
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
      let currentContents = try loadSystemFstabContents()
      let updatedContents = try updatedFstabContents(
        from: currentContents,
        for: volume,
        volumeUUID: volumeUUID,
        mountPoint: mountPoint,
        fileSystemType: fileSystemType
      )

      if updatedContents != currentContents {
        try installSystemFstabContents(updatedContents)
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
      let currentContents = try loadSystemFstabContents()
      let updatedContents = removingManagedFstabEntry(from: currentContents, for: volume)

      if updatedContents != currentContents {
        try installSystemFstabContents(updatedContents)
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

  // MARK: - Boot-Time Auto-Mount Blocking (fstab)

  /// The DiskArbitration approval callback only exists while MountMate runs,
  /// but diskarbitrationd mounts volumes during boot, before login items
  /// launch. This section persists each blocked volume as a "noauto" rule in
  /// /etc/fstab so macOS itself skips the auto-mount at startup.
  ///
  /// All writes are best-effort: when the admin prompt is cancelled the
  /// runtime block still applies for the current session, only the boot-time
  /// persistence is missing.

  /// Installs the boot-time "noauto" rule for a newly blocked volume. Runs on
  /// a background queue; failures are surfaced through the global error alert.
  private func installBlockedFstabEntry(for volume: Volume, info: ManagedVolumeInfo) {
    guard let volumeUUID = Self.normalizedSystemVolumeUUID(info.volumeUUID) else {
      print(
        "ℹ️ Volume “\(volume.name)” has no stable UUID; auto-mount blocking applies only while MountMate is running."
      )
      return
    }

    // User-initiated: always try once, even if a background reconcile was
    // previously declined.
    fstabAdminDeclinedThisSession = false

    let deviceIdentifier = volume.deviceIdentifier
    let fallbackFileSystemType = volume.fileSystemType
    let volumeName = volume.name
    let identifier = info.id

    fstabQueue.async { [weak self] in
      guard let self, !self.fstabAdminDeclinedThisSession else { return }
      do {
        let contents = try self.loadSystemFstabContents()
        let presentUUIDs = Self.managedFstabVolumeUUIDs(
          kinds: [Self.mountMateBlockPrefix], in: contents)
        if presentUUIDs.contains(volumeUUID) {
          self.refreshFstabBlockedUUIDs(from: contents)
          return
        }
        guard
          let fileSystemType = Self.fstabFileSystemType(
            plist: self.diskInfo(for: deviceIdentifier), fallback: fallbackFileSystemType)
        else {
          print(
            "⚠️ Could not determine the filesystem type of “\(volumeName)”; skipping its boot-time block rule."
          )
          return
        }

        // A block rule supersedes any other MountMate rule for this volume.
        let withoutManagedRules = Self.removingManagedFstabEntries(
          volumeUUID: volumeUUID, kinds: nil, from: contents)
        var normalized = Self.trimmedFstabContents(withoutManagedRules)
        if !normalized.isEmpty {
          normalized += "\n"
        }
        normalized += Self.blockedFstabEntry(
          volumeUUID: volumeUUID, fileSystemType: fileSystemType, identifier: identifier)

        try self.installSystemFstabContents(normalized)
        self.refreshFstabBlockedUUIDs(from: normalized)
        print("✅ Installed boot-time block rule for “\(volumeName)” in /etc/fstab.")
      } catch {
        self.fstabAdminDeclinedThisSession = true
        self.handleFstabRuleError(error)
      }
    }
  }

  /// Removes the boot-time "noauto" rule of an unblocked volume. Runs on a
  /// background queue; failures are surfaced through the global error alert.
  private func removeBlockedFstabEntry(for info: ManagedVolumeInfo) {
    guard let volumeUUID = Self.normalizedSystemVolumeUUID(info.volumeUUID) else { return }

    // User-initiated: always try once, even if a background reconcile was
    // previously declined.
    fstabAdminDeclinedThisSession = false

    fstabQueue.async { [weak self] in
      guard let self, !self.fstabAdminDeclinedThisSession else { return }
      do {
        let contents = try self.loadSystemFstabContents()
        let presentUUIDs = Self.managedFstabVolumeUUIDs(
          kinds: [Self.mountMateBlockPrefix], in: contents)
        guard presentUUIDs.contains(volumeUUID) else {
          self.refreshFstabBlockedUUIDs(from: contents)
          return
        }

        let updated = Self.removingManagedFstabEntries(
          volumeUUID: volumeUUID, kinds: [Self.mountMateBlockPrefix], from: contents)
        try self.installSystemFstabContents(updated)
        self.refreshFstabBlockedUUIDs(from: updated)
        print("✅ Removed boot-time block rule from /etc/fstab.")
      } catch {
        self.fstabAdminDeclinedThisSession = true
        self.handleFstabRuleError(error)
      }
    }
  }

  /// Schedules a coalesced boot-rule reconcile a few seconds out. Called when
  /// a blocked volume's auto-mount was just dissented — the volume is
  /// connected at that moment, so its missing rule can be installed.
  func scheduleBlockedFstabReconcile() {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isFstabReconcilePending else { return }
      self.isFstabReconcilePending = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
        guard let self else { return }
        self.isFstabReconcilePending = false
        self.reconcileBlockedFstabEntries(blockedInfos: self.blockedVolumes)
      }
    }
  }

  /// Syncs /etc/fstab with the blocked-volumes list: installs "noauto" rules
  /// for blocked volumes that are currently connected and lack one, and
  /// removes rules for volumes that are no longer blocked.
  ///
  /// `blockedInfos` must be snapshotted on the main thread by the caller.
  func reconcileBlockedFstabEntries(blockedInfos: [ManagedVolumeInfo]) {
    fstabQueue.async { [weak self] in
      guard let self, !self.fstabAdminDeclinedThisSession else { return }
      do {
        let contents = try self.loadSystemFstabContents()
        let presentUUIDs = Self.managedFstabVolumeUUIDs(
          kinds: [Self.mountMateBlockPrefix], in: contents)
        let desiredUUIDs = Set(
          blockedInfos.compactMap { Self.normalizedSystemVolumeUUID($0.volumeUUID) })
        let staleUUIDs = presentUUIDs.subtracting(desiredUUIDs)

        var additions: [(uuid: String, fileSystemType: String, identifier: String)] = []
        for info in blockedInfos {
          guard let uuid = Self.normalizedSystemVolumeUUID(info.volumeUUID),
            !presentUUIDs.contains(uuid)
          else { continue }
          guard let fileSystemType = self.fstabFileSystemType(forVolumeUUID: info.volumeUUID)
          else {
            print(
              "ℹ️ No boot-time block rule for “\(info.name)” yet: the volume is not connected right now. The rule will be installed the next time it tries to auto-mount."
            )
            continue
          }
          additions.append((uuid, fileSystemType, info.id))
        }

        guard !staleUUIDs.isEmpty || !additions.isEmpty else {
          self.refreshFstabBlockedUUIDs(from: contents)
          return
        }

        var updated = contents
        for uuid in staleUUIDs {
          updated = Self.removingManagedFstabEntries(
            volumeUUID: uuid, kinds: [Self.mountMateBlockPrefix], from: updated)
        }
        for addition in additions {
          // A block rule supersedes any other MountMate rule for this volume.
          updated = Self.removingManagedFstabEntries(
            volumeUUID: addition.uuid, kinds: nil, from: updated)
          var normalized = Self.trimmedFstabContents(updated)
          if !normalized.isEmpty {
            normalized += "\n"
          }
          normalized += Self.blockedFstabEntry(
            volumeUUID: addition.uuid, fileSystemType: addition.fileSystemType,
            identifier: addition.identifier)
          updated = normalized
        }

        try self.installSystemFstabContents(updated)
        self.refreshFstabBlockedUUIDs(from: updated)
        print("✅ Boot-time block rules in /etc/fstab are up to date.")
      } catch {
        self.fstabAdminDeclinedThisSession = true
        self.handleFstabRuleError(error)
      }
    }
  }

  /// The /etc/fstab rule line pair for a blocked volume. `none` as the mount
  /// point and `noauto` make diskarbitrationd skip the volume at boot while
  /// leaving manual mounts untouched.
  static func blockedFstabEntry(
    volumeUUID: String, fileSystemType: String, identifier: String
  ) -> String {
    "\(mountMateBlockPrefix) \(identifier)\nUUID=\(volumeUUID) none \(fileSystemType) rw,noauto\n"
  }

  /// Normalizes a volume identifier into an uppercased UUID string, or nil
  /// when the identifier is not a UUID (e.g. a fallback device name such as
  /// "disk4s2"), which cannot address a volume reliably across reboots.
  static func normalizedSystemVolumeUUID(_ raw: String) -> String? {
    guard let uuid = UUID(uuidString: raw) else { return nil }
    return uuid.uuidString
  }

  private func refreshFstabBlockedUUIDs(from contents: String) {
    let uuids = Self.managedFstabVolumeUUIDs(kinds: [Self.mountMateBlockPrefix], in: contents)
    DispatchQueue.main.async { [weak self] in
      self?.fstabBlockedVolumeUUIDs = uuids
    }
  }

  private func handleFstabRuleError(_ error: Error) {
    print("⚠️ Failed to update the /etc/fstab block rule: \(error.localizedDescription)")
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

  /// Resolves the filesystem type for a volume UUID by asking diskutil.
  /// Returns nil when the volume is not currently connected or its type
  /// cannot be determined.
  private func fstabFileSystemType(forVolumeUUID volumeUUID: String) -> String? {
    Self.fstabFileSystemType(plist: diskInfo(for: volumeUUID), fallback: nil)
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

  private func loadSystemFstabContents() throws -> String {
    let path = "/etc/fstab"
    guard FileManager.default.fileExists(atPath: path) else { return "" }
    return try String(contentsOfFile: path, encoding: .utf8)
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

  /// Removes MountMate-managed comment+entry pairs from `contents`.
  ///
  /// A pair is removed when its entry line addresses `volumeUUID` and, when
  /// `kinds` is non-nil, its comment belongs to one of those managed kinds.
  /// Matching by UUID (rather than by the comment's identifier) keeps removal
  /// working even when the volume's last-known identifiers have changed.
  static func removingManagedFstabEntries(
    volumeUUID: String, kinds: Set<String>?, from contents: String
  ) -> String {
    let lines = contents.components(separatedBy: .newlines)
    var filtered: [String] = []
    var index = 0

    while index < lines.count {
      if let kind = managedFstabKind(of: lines[index]), index + 1 < lines.count,
        entryAddressesUUID(lines[index + 1], volumeUUID),
        kinds == nil || kinds!.contains(kind)
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

  private static func entryAddressesUUID(_ line: String, _ volumeUUID: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("UUID=") else { return false }
    let uuid = trimmed.dropFirst("UUID=".count).prefix { !$0.isWhitespace }
    return uuid.lowercased() == volumeUUID.lowercased()
  }

  /// Volume UUIDs (uppercased) addressed by the managed entries of `kinds`.
  static func managedFstabVolumeUUIDs(kinds: Set<String>, in contents: String) -> Set<String> {
    let lines = contents.components(separatedBy: .newlines)
    var uuids: Set<String> = []
    var index = 0

    while index < lines.count {
      if let kind = managedFstabKind(of: lines[index]), kinds.contains(kind),
        index + 1 < lines.count
      {
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

  private func installSystemFstabContents(_ contents: String) throws {
    let normalizedContents = Self.trimmedFstabContents(contents)
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory
      .appendingPathComponent("mountmate-fstab-\(UUID().uuidString)")

    if !normalizedContents.isEmpty {
      try normalizedContents.write(to: temporaryURL, atomically: true, encoding: .utf8)
    }

    defer {
      try? fileManager.removeItem(at: temporaryURL)
    }

    let command: String
    if normalizedContents.isEmpty {
      command = "/bin/rm -f /etc/fstab"
    } else {
      command =
        "/usr/bin/install -m 644 -o root -g wheel \(temporaryURL.path.shellQuoted) /etc/fstab"
    }

    let script = "do shell script \(command.appleScriptStringLiteral) with administrator privileges"
    let result = runProcess(
      executable: "/usr/bin/osascript",
      arguments: ["-e", script],
      timeout: 300)
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
