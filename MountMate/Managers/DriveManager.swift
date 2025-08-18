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
            guard let allDisksData = allDisksOutput?.data(using: .utf8), !allDisksOutput!.isEmpty else {
                let errorMessage = "Failed to get disk list from `diskutil`. The command may have failed or returned empty."
                print("ERROR: \(errorMessage)")
                DispatchQueue.main.async {
                    self.physicalDisks = []
                    self.isRefreshing = false
                    if !self.isInitialLoadComplete { self.isInitialLoadComplete = true }
                    
                    self.operationError = AppAlert(
                        title: NSLocalizedString("Could Not Load Disks", comment: "Alert title for a failed refresh"),
                        message: NSLocalizedString(errorMessage, comment: "Alert message for a failed refresh"),
                        kind: .basic
                    )
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
                let errorMessage = "Failed to parse the data returned by `diskutil`. The format may have changed or the data could be corrupt."
                print("ERROR: \(errorMessage) - \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.physicalDisks = []
                    self.isRefreshing = false
                    if !self.isInitialLoadComplete { self.isInitialLoadComplete = true }
                    
                    self.operationError = AppAlert(
                        title: NSLocalizedString("Data Parsing Error", comment: "Alert title for a data parsing error"),
                        message: "\(NSLocalizedString(errorMessage, comment: "Alert message for a data parsing error"))\n\nDetails: \(error.localizedDescription)",
                        kind: .basic
                    )
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
                    self.handleDiskUtilError(error, for: disk.name ?? disk.id, with: nil, operation: .eject)
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
                    self.handleDiskUtilError(error, for: volume.name, with: volume, operation: .mount)
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
            let result = runShell("diskutil apfs unlockVolume \(volume.id) -stdinpassphrase", input: Data(passphrase.utf8))
            DispatchQueue.main.async {
                if let error = result.error, !error.isEmpty {
                    self.handleDiskUtilError(error, for: volume.name, with: volume, operation: .mount)
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
                    self.handleDiskUtilError(error, for: volume.name, with: volume, operation: .unmount)
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
            let infoPlist = getInfoForDisk(for: diskData["DeviceIdentifier"] as? String ?? "")
            if (infoPlist?["Internal"] as? Bool) ?? false && !shouldShowInternalDisks { continue }
            if diskData["Content"] as? String == "Apple_APFS_Container" { continue }
            
            guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
            let (allVolumes, apfsContainer) = getVolumes(for: diskData, in: allDisksAndPartitions)

            if !allVolumes.isEmpty {
                let connectionInfo = getConnectionInfo(from: infoPlist, isInternal: (infoPlist?["Internal"] as? Bool) ?? false)
                let diskName = infoPlist?["IORegistryEntryName"] as? String ?? infoPlist?["MediaName"] as? String ?? allVolumes.first(where: { $0.category == .user })?.name
                let totalBytes = diskData["Size"] as? Int64 ?? 0
                let stats = calculateParentDiskStats(totalBytes: totalBytes, volumes: allVolumes, apfsContainer: apfsContainer)

                let physicalDisk = PhysicalDisk(id: physicalIdentifier, connectionType: connectionInfo.type, volumes: allVolumes,
                                                name: diskName, totalSize: stats.total, freeSpace: stats.free,
                                                usagePercentage: stats.percentage, type: connectionInfo.diskType, usedSpace: stats.used)
                newDisks.append(physicalDisk)
            }
        }
        return newDisks.sorted {
            let order: (PhysicalDiskType) -> Int = { type in type == .internalDisk ? 0 : (type == .physical ? 1 : 2) }
            if order($0.type) != order($1.type) { return order($0.type) < order($1.type) }
            return ($0.name ?? "") < ($1.name ?? "")
        }
    }
    
    private func getVolumes(for diskData: [String: Any], in allDisks: [[String: Any]]) -> ([Volume], [String: Any]?) {
        var allVolumes: [Volume] = []
        var apfsContainer: [String: Any]?
        
        if let partitions = diskData["Partitions"] as? [[String: Any]] {
            for partitionData in partitions {
                if let contentType = partitionData["Content"] as? String, contentType == "Apple_APFS" {
                    let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
                    apfsContainer = findAPFSContainer(forStore: storeID, in: allDisks)
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
        
        return (allVolumes, apfsContainer)
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
    
    private func calculateParentDiskStats(totalBytes: Int64, volumes: [Volume], apfsContainer: [String: Any]?) -> (total: String?, free: String?, used: String?, percentage: Double?) {
        guard totalBytes > 0 else { return (nil, nil, nil, nil) }
        var usedBytes: Int64 = 0

        if let container = apfsContainer, let apfsVolumes = container["APFSVolumes"] as? [[String: Any]] {
            usedBytes = apfsVolumes.reduce(0) { $0 + ($1["CapacityInUse"] as? Int64 ?? 0) }
        } else {
            var hasMountedVolume = false
            for volume in volumes {
                if volume.isMounted, let mountPoint = volume.mountPoint, let attributes = getFileSystemAttributes(for: mountPoint) {
                    usedBytes += (attributes.total - attributes.free)
                    hasMountedVolume = true
                }
            }
            guard hasMountedVolume else { return (nil, nil, nil, nil) }
        }
        
        let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]; formatter.countStyle = .file
        let totalSizeStr = formatter.string(fromByteCount: totalBytes)
        let freeBytes = totalBytes - usedBytes
        let freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0)
        let usedSpaceStr = formatter.string(fromByteCount: usedBytes)
        let usagePercentage = min(1.0, Double(usedBytes) / Double(totalBytes))
        
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
    
    // MARK: - Error Handling
    
    private enum DiskOperation { case mount, unmount, eject }
    private enum DiskUtilError { case mountEFIVolume, unmountBusyVolume, mountInUseVolume, unmountInUseVolume, ejectInUseVolume, mountLockedVolume, other }

    private func handleDiskUtilError(_ error: String, for name: String, with volume: Volume?, operation: DiskOperation) {
        let parsedError = self.parseDiskUtilError(error, for: name, operation: operation)
        let title: String
        let message: String
        let kind: AppAlertKind

        switch parsedError {
            case .mountLockedVolume:
                title = String(format: NSLocalizedString("“%@” is locked", comment: "Alert title"), name)
                message = String(format: NSLocalizedString("Enter the password to unlock “%@”", comment: "Alert message"), name)
                let handler = { (passphrase: String) in
                    guard let volume = volume else { return }
                    self.mountLockedVolume(volume, passphrase: passphrase)
                }
                let lockedVolumeAlert = LockedVolumeAppAlert(onConfirm: handler)
                kind = .lockedVolume(lockedVolumeAlert)
            case .mountEFIVolume:
                title = NSLocalizedString("Mount Failed", comment: "Alert title")
                message = NSLocalizedString("The “EFI” partition cannot be mounted directly. This is a special system partition and this behavior is normal.", comment: "Error message")
                kind = .basic
            case .unmountBusyVolume:
                title = NSLocalizedString("Eject Failed", comment: "Alert title")
                message = String(format: NSLocalizedString("Failed to eject “%@” because one of its volumes is busy or in use.", comment: "Error message"), name)
                kind = .basic
            case .mountInUseVolume, .unmountInUseVolume, .ejectInUseVolume:
                let verb: String
                switch parsedError {
                case .mountInUseVolume: title = NSLocalizedString("Mount Failed", comment: "Alert title"); verb = NSLocalizedString("mount", comment: "verb")
                case .unmountInUseVolume: title = NSLocalizedString("Unmount Failed", comment: "Alert title"); verb = NSLocalizedString("unmount", comment: "verb")
                default: title = NSLocalizedString("Eject Failed", comment: "Alert title"); verb = NSLocalizedString("eject", comment: "verb")
                }
                message = String(format: NSLocalizedString("Failed to %@ “%@” because it is currently in use by another application.", comment: "Error message"), verb, name)
                kind = .basic
            case .other:
                let verb: String
                switch operation {
                case .mount: title = NSLocalizedString("Mount Failed", comment: "Alert title"); verb = "mount"
                case .unmount: title = NSLocalizedString("Unmount Failed", comment: "Alert title"); verb = "unmount"
                case .eject: title = NSLocalizedString("Eject Failed", comment: "Alert title"); verb = "eject"
                }
                message = "\(String(format: NSLocalizedString("An unknown error occurred while trying to %@ “%@”.", comment: "Error message"), verb, name))\n\nDetails:\n\(error)"
                kind = .basic
        }
        self.operationError = AppAlert(title: title, message: message, kind: kind)
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
