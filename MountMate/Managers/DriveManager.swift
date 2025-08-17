//  Created by homielab.com

import SwiftUI
import Foundation

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
        if isInitialLoadComplete {
            DispatchQueue.main.async { self.isRefreshing = true }
        }
        
        DispatchQueue.global(qos: qos).async { [weak self] in
            guard let self = self else { return }
            let allDisksOutput = runShell("diskutil list -plist").output
            guard let allDisksData = allDisksOutput?.data(using: .utf8) else {
                DispatchQueue.main.async {
                    self.physicalDisks = []
                    self.isRefreshing = false
                    if !self.isInitialLoadComplete { self.isInitialLoadComplete = true }
                }
                return
            }
            
            do {
                if let plist = try PropertyListSerialization.propertyList(from: allDisksData, options: [], format: nil) as? [String: Any] {
                    let newPhysicalDisks = self.parseDisks(from: plist)
                    DispatchQueue.main.async {
                        self.physicalDisks = newPhysicalDisks
                        self.isRefreshing = false
                        if !self.isInitialLoadComplete { self.isInitialLoadComplete = true }
                        
                        self.busyVolumeIdentifier = nil
                        self.busyEjectingIdentifier = nil
                        self.isUnmountingAll = false
                    }
                }
            } catch {
                print("Error parsing diskutil list plist: \(error)")
                DispatchQueue.main.async {
                    self.physicalDisks = []
                    self.isRefreshing = false
                    if !self.isInitialLoadComplete { self.isInitialLoadComplete = true }
                }
            }
        }
    }
    
    func unmountAllDrives() {
        let drivesToUnmount = self.physicalDisks
                .filter { $0.type == .physical || $0.type == .diskImage }
                .flatMap { $0.volumes }
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
                        error,
                        volume: nil,
                        volumeName: disk.name ?? disk.id,
                        operation: .eject,
                    )
                }
                self.busyEjectingIdentifier = nil
                self.refreshDrives(qos: .userInitiated)
            }
        }
    }

    private func handleDiskUtilError(_ error: String, volume: Volume?, volumeName: String, operation: DiskOperation) {
        let err = self.parseDiskUtilError(error, for: volumeName, operation: operation)
        let title: String
        let message: String
        let kind: AppAlertKind

        switch err {
            case .mountLockedVolume:
                // TODO: Localize.
                title = String(
                    format: "“%@” is locked",
                    volumeName
                )

                message = String(
                    format: "Enter the password to unlock “%@”",
                    volumeName
                )

                kind = .lockedVolume(LockedVolumeAppAlert { passphrase in
                    guard let volume else {
                        print("handleDiskUtilError was called for error '\(err)' without volume")

                        return
                    }

                    self.mountLockedVolume(volume, passphrase: passphrase)
                })
            case .mountEFIVolume:
                title = NSLocalizedString("Mount Failed", comment: "Alert title")
                message = String(
                    format: NSLocalizedString(
                        "The “EFI” partition cannot be mounted directly. This is a special system partition and this behavior is normal.",
                        comment: "User-friendly error for a failed EFI mount."
                    ),
                    volumeName
                )

                kind = .basic
            case .unmountBusyVolume:
                title = NSLocalizedString("Unmount Failed", comment: "Alert title")
                message = String(
                    format: NSLocalizedString(
                        "Failed to eject “%@” because one of its volumes is busy or in use.",
                        comment: "User-friendly error for a partial eject failure. %@ is disk name."
                    ),
                    volumeName
                )

                kind = .basic
            case .mountInUseVolume:
                title = NSLocalizedString("Mount Failed", comment: "Alert title")
                message = String(
                    format: NSLocalizedString(
                        "Failed to %@ “%@” because it is currently in use by another application.",
                        comment: "Error message"
                    ),
                    NSLocalizedString("mount", comment: "verb"),
                    volumeName
                )

                kind = .basic
            case .unmountInUseVolume:
                title = NSLocalizedString("Unmount Failed", comment: "Alert title")
                message = String(
                    format: NSLocalizedString(
                        "Failed to %@ “%@” because it is currently in use by another application.",
                        comment: "Error message"
                    ),
                    NSLocalizedString("unmount", comment: "verb"),
                    volumeName
                )

                kind = .basic
            case .ejectInUseVolume:
                title = NSLocalizedString("Eject Failed", comment: "Alert title")
                message = String(
                    format: NSLocalizedString(
                        "Failed to %@ “%@” because it is currently in use by another application.",
                        comment: "Error message"
                    ),
                    NSLocalizedString("eject", comment: "verb"),
                    volumeName
                )

                kind = .basic
            case .other:
                let genericFormatString = NSLocalizedString(
                    "An unknown error occurred while trying to %@ “%@”.",
                    comment: "Error message"
                )

                let actionString: String

                switch operation {
                    case .mount:
                        title = NSLocalizedString("Mount Failed", comment: "Alert title")
                        actionString = "mount"
                    case .unmount:
                        title = NSLocalizedString("Unmount Failed", comment: "Alert title")
                        actionString = "unmount"
                    case .eject:
                        title = NSLocalizedString("Eject Failed", comment: "Alert title")
                        actionString = "eject"
                }

                message = "\(String(format: genericFormatString, actionString, volumeName))\n\nDetails:\n\(error)"
                kind = .basic
        }

        self.operationError = AppAlert(title: title, message: message, kind: kind)
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
                        error,
                        volume: volume,
                        volumeName: volume.name,
                        operation: .mount
                    )
                }
                self.busyVolumeIdentifier = nil
                self.refreshDrives(qos: .userInitiated)
            }
        }
    }

    func mountLockedVolume(_ volume: Volume, passphrase: String) {
        let userInfo = ["deviceIdentifier": volume.id]
        NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
        DispatchQueue.main.async {
            self.busyVolumeIdentifier = volume.id
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = runShell("diskutil apfs unlockVolume \(volume.id) -stdinpassphrase", input: Data(passphrase.utf8))

            DispatchQueue.main.async {
                if let error = result.error, !error.isEmpty {
                    self.handleDiskUtilError(
                        error,
                        volume: nil,
                        volumeName: volume.name,
                        operation: .mount
                    )
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
                        error,
                        volume: nil,
                        volumeName: volume.name,
                        operation: .unmount,
                    )
                }
                self.busyVolumeIdentifier = nil
                self.refreshDrives(qos: .userInitiated)
            }
        }
    }

    // MARK: - Parsing and Data Creation Helpers

    private func parseDisks(from plist: [String: Any]) -> [PhysicalDisk] {
        guard let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var newDisks: [PhysicalDisk] = []
        
        let shouldShowInternalDisks = UserDefaults.standard.bool(forKey: "showInternalDisks")
        
        for diskData in allDisksAndPartitions {
            guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
            
            let infoPlist = getInfoForDisk(for: physicalIdentifier)

            let isInternal = (infoPlist?["Internal"] as? Bool) ?? false
            if isInternal && !shouldShowInternalDisks {
                continue
            }

            let isContainer = diskData["Content"] as? String == "Apple_APFS_Container"
            if isContainer {
                continue
            }
            
            var allVolumes: [Volume] = []
            var apfsContainer: [String: Any]?
                    
            if let partitions = diskData["Partitions"] as? [[String: Any]] {
                for partitionData in partitions {
                    if let contentType = partitionData["Content"] as? String, contentType == "Apple_APFS" {
                        let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
                        apfsContainer = findAPFSContainer(forStore: storeID, in: allDisksAndPartitions)
                        if let container = apfsContainer, let apfsVolumes = container["APFSVolumes"] as? [[String: Any]] {
                            allVolumes.append(contentsOf: apfsVolumes.compactMap { createVolume(from: $0) })
                        }
                    } else {
                        if let volume = createVolume(from: partitionData) { allVolumes.append(volume) }
                    }
                }
            }
            
            if let apfsVolumes = diskData["APFSVolumes"] as? [[String: Any]] {
                 allVolumes.append(contentsOf: apfsVolumes.compactMap { createVolume(from: $0) })
            }

            if !allVolumes.isEmpty {
                let connectionInfo = getConnectionInfo(from: infoPlist, isInternal: isInternal)
                let diskName = infoPlist?["IORegistryEntryName"] as? String ?? infoPlist?["MediaName"] as? String ?? allVolumes.first(where: { $0.category == .user })?.name
                let totalBytes = diskData["Size"] as? Int64 ?? 0
                let (totalSizeStr, freeSpaceStr, usedSpaceStr, usagePercentage) = calculateParentDiskStats(
                    totalBytes: totalBytes,
                    volumes: allVolumes,
                    apfsContainer: apfsContainer
                )

                let physicalDisk = PhysicalDisk(
                    id: physicalIdentifier, connectionType: connectionInfo.type, volumes: allVolumes,
                    name: diskName, totalSize: totalSizeStr, freeSpace: freeSpaceStr,
                    usagePercentage: usagePercentage, type: connectionInfo.diskType, usedSpace: usedSpaceStr
                )
                newDisks.append(physicalDisk)
            }
        }
        return newDisks.sorted {
            // Custom sort order: Internal -> Physical -> Disk Image
            let order: (PhysicalDiskType) -> Int = { type in
                switch type {
                case .internalDisk: return 0
                case .physical: return 1
                case .diskImage: return 2
                }
            }
            if order($0.type) != order($1.type) {
                return order($0.type) < order($1.type)
            }
            return ($0.name ?? "") < ($1.name ?? "")
        }
    }

    public func getInfoForDisk(for identifier: String) -> [String: Any]? {
        guard !identifier.isEmpty else { return nil }
        let infoOutput = runShell("diskutil info -plist \(identifier)").output
        return infoOutput?.data(using: .utf8)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] }
    }
    
    private func findAPFSContainer(forStore storeID: String, in allDisks: [[String: Any]]) -> [String: Any]? {
        return allDisks.first { disk in
            if let physicalStores = disk["APFSPhysicalStores"] as? [[String: Any]],
               let deviceID = physicalStores.first?["DeviceIdentifier"] as? String {
                return deviceID == storeID
            }
            return false
        }
    }
    
    private func calculateParentDiskStats(totalBytes: Int64, volumes: [Volume], apfsContainer: [String: Any]?) -> (String?, String?, String?, Double?) {
        guard totalBytes > 0 else { return (nil, nil, nil, nil) }

        var usedBytes: Int64 = 0

        if let container = apfsContainer, let capacityInUse = container["CapacityInUse"] as? Int64 {
            // For APFS, the container gives the single, true 'used' value.
            usedBytes = capacityInUse
        } else {
            // non-APFS disks (like ExFAT, HFS+) ---
            var hasMountedVolume = false
            for volume in volumes {
                if volume.isMounted, let mountPoint = volume.mountPoint, let attributes = getFileSystemAttributes(for: mountPoint) {
                    usedBytes = (attributes.total - attributes.free)
                    hasMountedVolume = true
                    if (apfsContainer != nil) {
                        break
                    }
                }
            }
            // If no volumes are mounted, we can't calculate used space.
            guard hasMountedVolume else { return (nil, nil, nil, nil) }
        }
        
        let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]; formatter.countStyle = .file
        let totalSizeStr = formatter.string(fromByteCount: totalBytes)
        let freeBytes = totalBytes - usedBytes
        let freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0) // Ensure free space is not negative
        let usedSpaceStr = formatter.string(fromByteCount: usedBytes)
        let usagePercentage = Double(usedBytes) / Double(totalBytes)
        
        return (totalSizeStr, freeSpaceStr, usedSpaceStr, usagePercentage)
    }

    private func createVolume(from volumeData: [String: Any]) -> Volume? {
        guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String,
              let volumeName = volumeData["VolumeName"] as? String,
              let volumeUUID = volumeData["VolumeUUID"] as? String,
              let diskUUID = volumeData["DiskUUID"] as? String else {
            return nil
        }
        
        if PersistenceManager.shared.isVolumeIgnored(volumeUUID: volumeUUID, diskUUID: diskUUID) {
            return nil
        }
        
        let isProtected = PersistenceManager.shared.isVolumeProtected(volumeUUID: volumeUUID, diskUUID: diskUUID)

        let parentInfo = getInfoForDisk(for: (volumeData["ParentWholeDisk"] as? String) ?? "")
        let isParentVirtual = (parentInfo?["VirtualOrPhysical"] as? String) == "Virtual"
        let contentType = volumeData["Content"] as? String
        let category: DriveCategory = (contentType == "EFI" && isParentVirtual) ? .system : .user

        let isMounted = volumeData["MountPoint"] != nil
        let mountPoint = volumeData["MountPoint"] as? String
        let fileSystemType = contentType ?? (volumeData["FilesystemName"] as? String) ?? "Unknown"
        
        var freeSpaceStr: String?, totalSizeStr: String?, usedSpaceStr: String?, usagePercentage: Double?
        if isMounted, let mountPoint = mountPoint, let attributes = getFileSystemAttributes(for: mountPoint) {
            let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]; formatter.countStyle = .file
            freeSpaceStr = formatter.string(fromByteCount: attributes.free)
            totalSizeStr = formatter.string(fromByteCount: attributes.total)
            usedSpaceStr = formatter.string(fromByteCount: attributes.total - attributes.free)
            if attributes.total > 0 { usagePercentage = Double(attributes.total - attributes.free) / Double(attributes.total) }
        }
        
        return Volume(
            id: volumeUUID,
            deviceIdentifier: deviceIdentifier,
            diskUUID: diskUUID,
            name: volumeName,
            isMounted: isMounted,
            mountPoint: mountPoint,
            freeSpace: freeSpaceStr,
            totalSize: totalSizeStr,
            fileSystemType: fileSystemType,
            usagePercentage: usagePercentage,
            category: category,
            isProtected: isProtected,
            usedSpace: usedSpaceStr
        )
    }

    private func getConnectionInfo(from infoPlist: [String: Any]?, isInternal: Bool) -> (type: String, diskType: PhysicalDiskType) {
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
    
    // MARK: - Error Parsing
    
    private enum DiskOperation { case mount, unmount, eject }

    private enum DiskUtilError {
        case mountEFIVolume,
             unmountBusyVolume,
             mountInUseVolume,
             unmountInUseVolume,
             ejectInUseVolume,
             mountLockedVolume,
             other
    }

    private func parseDiskUtilError(_ rawError: String, for name: String, operation: DiskOperation) -> DiskUtilError {
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

        if rawError.contains("This is an encrypted and locked APFS Volume; use \"diskutil apfs unlockVolume\"") {
            return .mountLockedVolume
        }

        return .other
    }

    private func getFileSystemAttributes(for path: String) -> (free: Int64, total: Int64)? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeSpace = attributes[.systemFreeSize] as? NSNumber,
               let totalSize = attributes[.systemSize] as? NSNumber {
                return (free: freeSpace.int64Value, total: totalSize.int64Value)
            }
        } catch {
            print("Error getting file system attributes for \(path): \(error)")
        }
        return nil
    }

    // MARK: - Notification Handling

    private func setupDiskChangeObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(self, selector: #selector(handleDiskNotification), name: NSWorkspace.didMountNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleDiskNotification), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func handleDiskNotification(notification: NSNotification) {
        refreshDebounceTimer?.invalidate()
        refreshDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                 print("Disk notification received for volume: \(volumeURL.lastPathComponent). Refreshing list.")
            } else {
                print("Disk notification received. Refreshing list.")
            }
            self?.refreshDrives()
        }
    }
}
