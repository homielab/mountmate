//  Created by homielab.com

import Foundation
import SwiftUI

class DriveManager: ObservableObject {
  static let shared = DriveManager()

  @Published var physicalDisks: [PhysicalDisk] = []
  @Published var isInitialLoadComplete = false
  @Published var isRefreshing = false
  @Published var busyVolumeIdentifier: String? = nil
  @Published var busyEjectingIdentifier: String? = nil
  @Published var isUnmountingAll = false
  @Published var operationError: AppAlert? = nil

  private var refreshDebounceTimer: Timer?

  private init() {
    setupDiskChangeObservers()
    refreshDrives()
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    refreshDebounceTimer?.invalidate()
  }

  // MARK: - Public Actions

  func refreshDrives(qos: DispatchQoS.QoSClass = .background) {
    guard !isRefreshing else {
      print("Refresh already in progress. Skipping.")
      return
    }

    if isInitialLoadComplete {
      DispatchQueue.main.async { self.isRefreshing = true }
    }

    DispatchQueue.global(qos: qos).async { [weak self] in
      guard let self = self else { return }

      // #if DEBUG
      // let (output, error) = self.loadMockData()
      // #else
      let (output, error) = runShell("diskutil list -plist")
      // #endif

      if let error = error, !error.isEmpty {
        let errorMessage =
          "The 'diskutil' command failed to execute. This can happen due to permission issues."
        print("SHELL ERROR: \(errorMessage) - Details: \(error)")
        self.handleRefreshFailure(
          titleKey: "Command Execution Failed",
          messageKey:
            "\(errorMessage)\n\nPlease check your System Settings under Privacy & Security > Files and Folders to ensure MountMate has access.",
          details: error
        )
        return
      }

      guard let allDisksData = output?.data(using: .utf8), !output!.isEmpty else {
        let errorMessage =
          "Failed to get disk list. The 'diskutil' command returned no data."
        print("DATA ERROR: \(errorMessage)")
        self.handleRefreshFailure(
          titleKey: "Could Not Load Disks",
          messageKey: "Failed to get disk list. The 'diskutil' command returned no data.",
          details: nil
        )

        return
      }

      do {
        if let plist = try PropertyListSerialization.propertyList(
          from: allDisksData, options: [], format: nil) as? [String: Any]
        {
          let newPhysicalDisks = self.parseDisks(from: plist)
          self.updateState(with: newPhysicalDisks, isComplete: true)
        }
      } catch {
        let errorMessage = "Failed to parse the data returned by `diskutil`."
        print("PARSING ERROR: \(errorMessage) - \(error.localizedDescription)")
        self.handleRefreshFailure(
          titleKey: "Data Parsing Error",
          messageKey: "Failed to parse the data returned by `diskutil`.",
          details: error.localizedDescription
        )
      }
    }
  }

  private func handleRefreshFailure(titleKey: String, messageKey: String, details: String?) {
    DispatchQueue.main.async {
      self.physicalDisks = []
      self.isRefreshing = false
      if !self.isInitialLoadComplete { self.isInitialLoadComplete = true }

      var fullMessage = NSLocalizedString(messageKey, comment: "Alert message")
      if let details = details {
        if details.lowercased().contains("permission") || details.lowercased().contains("timed out")
        {
          let permissionSuggestion = NSLocalizedString(
            "\n\nPlease grant MountMate 'Full Disk Access' in System Settings > Privacy & Security.",
            comment: "Permission suggestion text")
          fullMessage += permissionSuggestion
        }
        fullMessage += "\n\nDetails:\n\(details)"
      }

      self.operationError = AppAlert(
        title: NSLocalizedString(titleKey, comment: "Alert title"),
        message: fullMessage,
        kind: .basic
      )
    }
  }

  private func updateState(with disks: [PhysicalDisk], isComplete: Bool) {
    DispatchQueue.main.async {
      self.physicalDisks = disks
      self.isRefreshing = false
      if !self.isInitialLoadComplete && isComplete { self.isInitialLoadComplete = true }
      self.busyVolumeIdentifier = nil
      self.busyEjectingIdentifier = nil
      self.isUnmountingAll = false
    }
  }

  private func loadMockData() -> (output: String?, error: String?) {
    // Look for the file named "testDisks.plist" in the app's bundle.
    guard let url = Bundle.main.url(forResource: "testDisks", withExtension: "plist") else {
      print(
        "⚠️ MOCK DATA ERROR: testDisks.plist not found in the app bundle. Make sure it's added to the target."
      )
      return (nil, "testDisks.plist not found")
    }

    do {
      // Read the file's content into a string.
      let output = try String(contentsOf: url)
      return (output, nil)
    } catch {
      print("❌ MOCK DATA ERROR: Could not read content from testDisks.plist. Error: \(error)")
      return (nil, error.localizedDescription)
    }
  }

  func unmountAllDrives() {
    let drivesToUnmount = self.physicalDisks
      .filter { $0.type == .physical || $0.type == .diskImage }
      .flatMap { $0.partitions }
      .filter { $0.isMounted && $0.category == .user && !$0.isProtected }

    guard !drivesToUnmount.isEmpty else { return }

    DispatchQueue.main.async { self.isUnmountingAll = true }

    DispatchQueue.global(qos: .userInitiated).async {
      for drive in drivesToUnmount {
        _ = runShell("diskutil unmount \(drive.id)")
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.refreshDrives(qos: .userInitiated)
      }
    }
  }

  func eject(disk: PhysicalDisk) {
    DispatchQueue.main.async { self.busyEjectingIdentifier = disk.id }
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runShell("diskutil eject \(disk.id)")
      DispatchQueue.main.async {
        if let error = result.error, !error.isEmpty {
          self.handleDiskUtilError(
            error, for: disk.name ?? disk.id, with: nil, operation: .eject)
        }
        self.busyEjectingIdentifier = nil
        self.refreshDrives(qos: .userInitiated)
      }
    }
  }

  func mount(volume: Volume) {
    let userInfo = ["deviceIdentifier": volume.deviceIdentifier]
    NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    DispatchQueue.main.async { self.busyVolumeIdentifier = volume.id }
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runShell("diskutil mount \(volume.deviceIdentifier)")
      DispatchQueue.main.async {
        if let error = result.error, !error.isEmpty {
          self.handleDiskUtilError(
            error, for: volume.name, with: volume, operation: .mount)
        }
        self.busyVolumeIdentifier = nil
        self.refreshDrives(qos: .userInitiated)
      }
    }
  }

  func mountLockedVolume(_ volume: Volume, passphrase: String) {
    let userInfo = ["deviceIdentifier": volume.id]
    NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
    DispatchQueue.main.async { self.busyVolumeIdentifier = volume.id }

    DispatchQueue.global(qos: .userInitiated).async {
      // Note the use of the 'input' parameter here
      let result = runShell(
        "diskutil apfs unlockVolume \(volume.id) -stdinpassphrase",
        input: Data(passphrase.utf8))
      DispatchQueue.main.async {
        if let error = result.error, !error.isEmpty {
          self.handleDiskUtilError(
            error, for: volume.name, with: volume, operation: .mount)
        }
        self.busyVolumeIdentifier = nil
        self.refreshDrives(qos: .userInitiated)
      }
    }
  }

  func unmount(volume: Volume) {
    DispatchQueue.main.async { self.busyVolumeIdentifier = volume.id }
    DispatchQueue.global(qos: .userInitiated).async {
      let result = runShell("diskutil unmount \(volume.deviceIdentifier)")
      DispatchQueue.main.async {
        if let error = result.error, !error.isEmpty {
          self.handleDiskUtilError(
            error, for: volume.name, with: volume, operation: .unmount)
        }
        self.busyVolumeIdentifier = nil
        self.refreshDrives(qos: .userInitiated)
      }
    }
  }

  // MARK: - Parsing and Data Creation Helpers

  private func parseDisks(from plist: [String: Any]) -> [PhysicalDisk] {
    guard let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
      return []
    }

    // Step 1: Create a set of all identifiers that are children (partitions) of another disk.
    var childDeviceIDs = Set<String>()
    for diskData in allDisksAndPartitions {
      if let partitions = diskData["Partitions"] as? [[String: Any]] {
        for partition in partitions {
          if let id = partition["DeviceIdentifier"] as? String {
            childDeviceIDs.insert(id)
          }
        }
      }
    }

    // Step 2: Identify the true root disks. A root disk is any disk whose identifier
    // is NOT in the set of child identifiers.
    let rootDisks = allDisksAndPartitions.filter { diskData in
      guard let id = diskData["DeviceIdentifier"] as? String else { return false }
      return !childDeviceIDs.contains(id)
    }

    let shouldShowInternalDisks = UserDefaults.standard.bool(forKey: "showInternalDisks")
    var newDisks: [PhysicalDisk] = []

    // Step 3: Iterate ONLY through the identified root disks. This prevents all duplicates.
    for diskData in rootDisks {
      let infoPlist = getInfoForDisk(for: diskData["DeviceIdentifier"] as? String ?? "")
      if (infoPlist?["Internal"] as? Bool) ?? false && !shouldShowInternalDisks { continue }

      guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }

      var partitions: [Volume] = []
      var containers: [APFSContainer] = []

      // Builds the hierarchy downwards from the root disk.
      if let diskPartitions = diskData["Partitions"] as? [[String: Any]] {
        for partitionData in diskPartitions {
          if let contentType = partitionData["Content"] as? String,
            contentType == "Apple_APFS"
          {
            let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
            if let containerData = findAPFSContainer(
              forStore: storeID, in: allDisksAndPartitions),
              let container = createContainer(from: containerData)
            {
              containers.append(container)
            }
          } else {
            if let volume = createVolume(from: partitionData, snapshotsData: nil) {
              partitions.append(volume)
            }
          }
        }
      } else if diskData["APFSVolumes"] as? [[String: Any]] != nil {
        if let container = createContainer(from: diskData) {
          containers.append(container)
        }
      }

      if !partitions.isEmpty || !containers.isEmpty {
        let connectionInfo = getConnectionInfo(
          from: infoPlist, isInternal: (infoPlist?["Internal"] as? Bool) ?? false)
        let diskName =
          infoPlist?["IORegistryEntryName"] as? String ?? infoPlist?["MediaName"]
          as? String
          ?? (partitions.first ?? containers.first?.volumes.first)?.name
        let totalBytes = diskData["Size"] as? Int64 ?? 0

        let allVolumesForStats = partitions + containers.flatMap { $0.volumes }
        let stats = calculateParentDiskStats(
          totalBytes: totalBytes, volumes: allVolumesForStats)

        let physicalDisk = PhysicalDisk(
          id: physicalIdentifier, diskUUID: infoPlist?["DiskUUID"] as? String,
          connectionType: connectionInfo.type, name: diskName,
          totalSize: stats.total, freeSpace: stats.free, usedSpace: stats.used,
          storageError: stats.error, usagePercentage: stats.percentage,
          type: connectionInfo.diskType, partitions: partitions, containers: containers)
        newDisks.append(physicalDisk)
      }
    }

    return newDisks.sorted {
      let order: (PhysicalDiskType) -> Int = { type in
        type == .internalDisk ? 0 : (type == .physical ? 1 : 2)
      }
      if order($0.type) != order($1.type) { return order($0.type) < order($1.type) }
      return ($0.name ?? "") < ($1.name ?? "")
    }
  }

  private func createContainer(from containerData: [String: Any]) -> APFSContainer? {
    guard let containerID = containerData["DeviceIdentifier"] as? String,
      let apfsVolumesData = containerData["APFSVolumes"] as? [[String: Any]]
    else {
      return nil
    }

    let volumes = apfsVolumesData.compactMap {
      createVolume(from: $0, snapshotsData: $0["MountedSnapshots"] as? [[String: Any]])
    }
    return APFSContainer(id: containerID, volumes: volumes)
  }

  public func getInfoForDisk(for identifier: String) -> [String: Any]? {
    guard !identifier.isEmpty else { return nil }
    let infoOutput = runShell("diskutil info -plist \(identifier)").output
    return infoOutput?.data(using: .utf8)
      .flatMap {
        try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
          as? [String: Any]
      }
  }

  private func findAPFSContainer(forStore storeID: String, in allDisks: [[String: Any]])
    -> [String:
    Any]?
  {
    return allDisks.first { disk in
      if let physicalStores = disk["APFSPhysicalStores"] as? [[String: Any]],
        let deviceID = physicalStores.first?["DeviceIdentifier"] as? String
      {
        return deviceID == storeID
      }
      return false
    }
  }

  private func calculateParentDiskStats(totalBytes: Int64, volumes: [Volume]) -> (
    total: String?, free: String?, used: String?, percentage: Double?, error: String?
  ) {
    if volumes.compactMap({ $0.storageError }).first != nil {
      let errorMessage = NSLocalizedString(
        "Could not calculate total usage because an error occurred on one of its volumes.",
        comment: "Parent disk error message")
      return (nil, nil, nil, nil, errorMessage)
    }

    guard totalBytes > 0 else { return (nil, nil, nil, nil, nil) }

    let usedBytes = volumes.reduce(0) { $0 + ($1.usedBytes ?? 0) }

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
    formatter.countStyle = .file
    let totalSizeStr = formatter.string(fromByteCount: totalBytes)
    let freeBytes = totalBytes - usedBytes
    let freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0)
    let usedSpaceStr = formatter.string(fromByteCount: usedBytes)
    let usagePercentage = totalBytes > 0 ? min(1.0, Double(usedBytes) / Double(totalBytes)) : 0

    return (totalSizeStr, freeSpaceStr, usedSpaceStr, usagePercentage, nil)
  }

  private func createVolume(from volumeData: [String: Any], snapshotsData: [[String: Any]]?)
    -> Volume?
  {
    guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String else { return nil }

    let volumeUUID = volumeData["VolumeUUID"] as? String ?? deviceIdentifier
    let diskUUID = volumeData["DiskUUID"] as? String

    let volumeName =
      volumeData["VolumeName"] as? String ?? volumeData["Content"] as? String
      ?? deviceIdentifier

    let tempVolume = Volume(
      id: volumeUUID, deviceIdentifier: deviceIdentifier, diskUUID: diskUUID,
      name: volumeName,
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, usagePercentage: nil, storageError: nil, fileSystemType: nil,
      category: .user,
      isProtected: false, snapshots: [])
    if PersistenceManager.shared.isVolumeIgnored(tempVolume) { return nil }

    let isProtected = PersistenceManager.shared.isVolumeProtected(tempVolume)
    let snapshots = snapshotsData?.compactMap { createSnapshot(from: $0) } ?? []

    let parentInfo = getInfoForDisk(for: (volumeData["ParentWholeDisk"] as? String) ?? "")
    let isParentVirtual = (parentInfo?["VirtualOrPhysical"] as? String) == "Virtual"
    let contentType = volumeData["Content"] as? String
    let category: DriveCategory = (contentType == "EFI" && isParentVirtual) ? .system : .user

    let isMounted = volumeData["MountPoint"] != nil
    let mountPoint = volumeData["MountPoint"] as? String
    let fileSystemType = contentType ?? (volumeData["FilesystemName"] as? String) ?? "Unknown"

    var freeSpaceStr: String?
    var totalSizeStr: String?
    var usedSpaceStr: String?
    var usagePercentage: Double?
    var usedBytes: Int64?
    var storageError: String?

    if let totalSize = volumeData["Size"] as? Int64, totalSize > 0 {
      let formatter = ByteCountFormatter()
      formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
      formatter.countStyle = .file
      totalSizeStr = formatter.string(fromByteCount: totalSize)

      var calculatedUsedBytes: Int64 = 0
      if let capacityInUse = volumeData["CapacityInUse"] as? Int64 {
        calculatedUsedBytes = capacityInUse
      } else if isMounted, let mountPoint = mountPoint {
        do {
          let attributes = try getFileSystemAttributes(for: mountPoint)

          if let totalSize = volumeData["Size"] as? Int64, totalSize > 0 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
            formatter.countStyle = .file
            totalSizeStr = formatter.string(fromByteCount: totalSize)

            calculatedUsedBytes = attributes.total - attributes.free
          }
        } catch {
          print(
            "Error getting file system attributes for \(volumeName): \(error.localizedDescription)"
          )
          storageError = NSLocalizedString(
            "Could not read storage details. Please grant MountMate 'Full Disk Access' or 'Files and Folders' permissions in System Settings > Privacy & Security.",
            comment: "Permission error message")
        }
      }

      usedBytes = calculatedUsedBytes

      let freeBytes = totalSize - calculatedUsedBytes
      freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0)
      usedSpaceStr = formatter.string(fromByteCount: calculatedUsedBytes)
      usagePercentage = Double(calculatedUsedBytes) / Double(totalSize)
    }

    return Volume(
      id: volumeUUID, deviceIdentifier: deviceIdentifier, diskUUID: diskUUID,
      name: volumeName,
      isMounted: isMounted, mountPoint: mountPoint, freeSpace: freeSpaceStr,
      totalSize: totalSizeStr, usedSpace: usedSpaceStr, usedBytes: usedBytes,
      usagePercentage: usagePercentage,
      storageError: storageError, fileSystemType: fileSystemType,
      category: category, isProtected: isProtected, snapshots: snapshots)
  }

  private func createSnapshot(from snapshotData: [String: Any]) -> APFSSnapshot? {
    guard let name = snapshotData["SnapshotName"] as? String,
      let uuid = snapshotData["SnapshotUUID"] as? String
    else { return nil }
    return APFSSnapshot(id: uuid, name: name)
  }

  private func getConnectionInfo(from infoPlist: [String: Any]?, isInternal: Bool) -> (
    type: String, diskType: PhysicalDiskType
  ) {
    let defaultType = NSLocalizedString("Unknown", comment: "Unknown connection type")
    guard let info = infoPlist else { return (defaultType, .physical) }

    let diskType: PhysicalDiskType
    if isInternal {
      diskType = .internalDisk
    } else if info["VirtualOrPhysical"] as? String == "Virtual" {
      diskType = .diskImage
    } else {
      diskType = .physical
    }

    let connectionType: String
    if diskType == .diskImage {
      connectionType = NSLocalizedString("Disk Image", comment: "Disk Image")
    } else {
      connectionType = info["BusProtocol"] as? String ?? defaultType
    }

    return (connectionType, diskType)
  }

  // MARK: - Error Handling

  private enum DiskOperation { case mount, unmount, eject }
  private enum DiskUtilError {
    case mountEFIVolume, unmountBusyVolume, mountInUseVolume, unmountInUseVolume,
      ejectInUseVolume,
      mountLockedVolume, other
  }

  private func handleDiskUtilError(
    _ error: String, for name: String, with volume: Volume?, operation: DiskOperation
  ) {
    let parsedError = self.parseDiskUtilError(error, for: name, operation: operation)
    let title: String
    let message: String
    let kind: AppAlertKind

    switch parsedError {
    case .mountLockedVolume:
      title = String(
        format: NSLocalizedString("“%@” is locked", comment: "Alert title"), name)
      message = String(
        format: NSLocalizedString(
          "Enter the password to unlock “%@”", comment: "Alert message"),
        name)
      let handler = { (passphrase: String) in
        guard let volume = volume else { return }
        self.mountLockedVolume(volume, passphrase: passphrase)
      }
      let lockedVolumeAlert = LockedVolumeAppAlert(onConfirm: handler)
      kind = .lockedVolume(lockedVolumeAlert)
    case .mountEFIVolume:
      title = NSLocalizedString("Mount Failed", comment: "Alert title")
      message = NSLocalizedString(
        "The “EFI” partition cannot be mounted directly. This is a special system partition and this behavior is normal.",
        comment: "Error message")
      kind = .basic
    case .unmountBusyVolume:
      title = NSLocalizedString("Eject Failed", comment: "Alert title")
      message = String(
        format: NSLocalizedString(
          "Failed to eject “%@” because one of its volumes is busy or in use.",
          comment: "Error message"), name)
      kind = .basic
    case .mountInUseVolume, .unmountInUseVolume, .ejectInUseVolume:
      let verb: String
      switch parsedError {
      case .mountInUseVolume:
        title = NSLocalizedString("Mount Failed", comment: "Alert title")
        verb = NSLocalizedString("mount", comment: "verb")
      case .unmountInUseVolume:
        title = NSLocalizedString("Unmount Failed", comment: "Alert title")
        verb = NSLocalizedString("unmount", comment: "verb")
      default:
        title = NSLocalizedString("Eject Failed", comment: "Alert title")
        verb = NSLocalizedString("eject", comment: "verb")
      }
      message = String(
        format: NSLocalizedString(
          "Failed to %@ “%@” because it is currently in use by another application.",
          comment: "Error message"), verb, name)
      kind = .basic
    case .other:
      let verb: String
      switch operation {
      case .mount:
        title = NSLocalizedString("Mount Failed", comment: "Alert title")
        verb = "mount"
      case .unmount:
        title = NSLocalizedString("Unmount Failed", comment: "Alert title")
        verb = "unmount"
      case .eject:
        title = NSLocalizedString("Eject Failed", comment: "Alert title")
        verb = "eject"
      }
      message =
        "\(String(format: NSLocalizedString("An unknown error occurred while trying to %@ “%@”.", comment: "Error message"), verb, name))\n\nDetails:\n\(error)"
      kind = .basic
    }
    self.operationError = AppAlert(title: title, message: message, kind: kind)
  }

  private func parseDiskUtilError(_ rawError: String, for name: String, operation: DiskOperation)
    -> DiskUtilError
  {
    let lowerCaseError = rawError.lowercased()

    if operation == .mount && name.uppercased() == "EFI" {
      return .mountEFIVolume
    }

    if lowerCaseError.contains("at least one volume could not be unmounted") {
      return .unmountBusyVolume
    }

    if lowerCaseError.contains("busy") || lowerCaseError.contains("in use") {
      return switch operation {
      case .mount: .mountInUseVolume
      case .unmount: .unmountInUseVolume
      case .eject: .ejectInUseVolume
      }
    }

    if rawError.contains(
      "This is an encrypted and locked APFS Volume; use \"diskutil apfs unlockVolume\"")
    {
      return .mountLockedVolume
    }

    return .other
  }

  private func getFileSystemAttributes(for path: String) throws -> (free: Int64, total: Int64) {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
    if let freeSpace = attributes[.systemFreeSize] as? NSNumber,
      let totalSize = attributes[.systemSize] as? NSNumber
    {
      return (free: freeSpace.int64Value, total: totalSize.int64Value)
    }
    throw NSError(
      domain: "com.homielab.mountmate", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "File system attribute keys are missing."])
  }

  // MARK: - Notification Handling

  private func setupDiskChangeObservers() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    notificationCenter.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: NSWorkspace.didMountNotification,
      object: nil)
    notificationCenter.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: NSWorkspace.didUnmountNotification,
      object: nil)
  }

  @objc private func handleDiskNotification(notification: NSNotification) {
    refreshDebounceTimer?.invalidate()
    refreshDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
      [weak self] _ in
      if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
        print(
          "Disk notification received for volume: \(volumeURL.lastPathComponent). Refreshing list."
        )
      } else {
        print("Disk notification received. Refreshing list.")
      }
      self?.refreshDrives()
    }
  }
}
