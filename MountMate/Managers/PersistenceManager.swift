//  Created by homielab.com

import Combine
import Foundation

class PersistenceManager: ObservableObject {
  static let shared = PersistenceManager()

  private let protectedVolumesKey = "mountmate_protectedVolumes_v4"
  private let ignoredVolumesKey = "mountmate_ignoredVolumes_v4"
  private let blockedVolumesKey = "mountmate_blockedVolumes_v1"
  private let networkSharesKey = "mountmate_networkShares_v1"
  private let customMountPointsKey = "mountmate_customMountPoints_v1"

  @Published var protectedVolumes: [ManagedVolumeInfo]
  @Published var ignoredVolumes: [ManagedVolumeInfo]
  @Published var blockedVolumes: [ManagedVolumeInfo]
  @Published var networkShares: [NetworkShare]
  @Published var customMountPoints: [VolumeCustomMountPoint]
  private let mountMateFstabPrefix = "# MountMate custom mount:"

  private init() {
    self.protectedVolumes = Self.load(from: protectedVolumesKey)
    self.ignoredVolumes = Self.load(from: ignoredVolumesKey)
    self.blockedVolumes = Self.load(from: blockedVolumesKey)
    self.networkShares = Self.load(from: networkSharesKey)
    self.customMountPoints = Self.load(from: customMountPointsKey)
  }

  // MARK: - Actions

  @discardableResult
  func protect(volume: Volume) -> Bool {
    guard let diskUUID = volume.diskUUID else { return false }
    let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
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
    guard let diskUUID = volume.diskUUID else { return false }
    let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
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
    guard let diskUUID = volume.diskUUID else { return false }
    let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
    guard !blockedVolumes.contains(where: { $0.id == info.id }) else { return true }
    blockedVolumes.append(info)
    saveBlockedVolumes()
    return true
  }

  func unblock(info: ManagedVolumeInfo) {
    blockedVolumes.removeAll { $0.id == info.id }
    saveBlockedVolumes()
  }

  func addNetworkShare(_ share: NetworkShare) {
    networkShares.append(share)
    saveNetworkShares()
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
  func withAccessToCustomMountPoint<T>(for volume: Volume, _ body: (URL) throws -> T) rethrows -> T? {
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
    let candidates = [
      plist?["FilesystemType"] as? String,
      plist?["FilesystemName"] as? String,
      plist?["Content"] as? String,
      volume.fileSystemType,
    ].compactMap { $0 }

    for candidate in candidates {
      if let mapped = mapFstabFileSystemType(candidate) {
        return mapped
      }
    }

    return nil
  }

  private func diskInfo(for deviceIdentifier: String) -> [String: Any]? {
    guard !deviceIdentifier.isEmpty else { return nil }
    let output = runShell("diskutil info -plist \(deviceIdentifier.shellQuoted)").output
    guard let data = output?.data(using: .utf8) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
      as? [String: Any]
  }

  private func mapFstabFileSystemType(_ rawValue: String) -> String? {
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

    var normalized = trimmedFstabContents(withoutManagedEntry)
    if !normalized.isEmpty {
      normalized += "\n"
    }

    let entryLine =
      "UUID=\(volumeUUID) \(fstabEscapedField(mountPoint)) \(fileSystemType) rw"
    normalized += "\(managedFstabComment(for: volume))\n\(entryLine)\n"
    return normalized
  }

  private func removingManagedFstabEntry(from contents: String, for volume: Volume) -> String {
    let comment = managedFstabComment(for: volume)
    let lines = contents.components(separatedBy: .newlines)
    var filtered: [String] = []
    var index = 0

    while index < lines.count {
      if lines[index] == comment {
        index += 1
        if index < lines.count {
          index += 1
        }
        continue
      }
      filtered.append(lines[index])
      index += 1
    }

    return trimmedFstabContents(filtered.joined(separator: "\n"))
  }

  private func installSystemFstabContents(_ contents: String) throws {
    let normalizedContents = trimmedFstabContents(contents)
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
    let result = runShell("/usr/bin/osascript -e \(script.shellQuoted)")
    if let error = result.error, !error.isEmpty {
      throw NSError(
        domain: "MountMate",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: error])
    }
  }

  private func managedFstabComment(for volume: Volume) -> String {
    "\(mountMateFstabPrefix) \(stableIdentifier(for: volume))"
  }

  private func isConflictingFstabEntry(_ line: String, volumeUUID: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
    return trimmed.hasPrefix("UUID=\(volumeUUID) ")
  }

  private func fstabEscapedField(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: " ", with: "\\040")
      .replacingOccurrences(of: "\t", with: "\\011")
  }

  private func trimmedFstabContents(_ contents: String) -> String {
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
  private func saveNetworkShares() { save(networkShares, to: networkSharesKey) }
  private func saveCustomMountPoints() { save(customMountPoints, to: customMountPointsKey) }

}
