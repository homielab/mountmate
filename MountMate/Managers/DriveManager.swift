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
        let drivesToUnmount = self.physicalDisks.flatMap { $0.volumes }.filter { $0.isMounted && $0.category == .user && !$0.isProtected }
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
                    let friendlyMessage = self.parseDiskUtilError(error, for: disk.name ?? disk.id, operation: .eject)
                    self.operationError = AppAlert(title: NSLocalizedString("Eject Failed", comment: "Alert title"), message: friendlyMessage)
                }
                self.busyEjectingIdentifier = nil
                self.refreshDrives(qos: .userInitiated)
            }
        }
    }

    func mount(volume: Volume) {
        let userInfo = ["deviceIdentifier": volume.id]
        NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
        DispatchQueue.main.async { self.busyVolumeIdentifier = volume.id }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runShell("diskutil mount \(volume.id)")
            DispatchQueue.main.async {
                if let error = result.error, !error.isEmpty {
                    let friendlyMessage = self.parseDiskUtilError(error, for: volume.name, operation: .mount)
                    self.operationError = AppAlert(title: NSLocalizedString("Mount Failed", comment: "Alert title"), message: friendlyMessage)
                }
                self.busyVolumeIdentifier = nil
                self.refreshDrives(qos: .userInitiated)
            }
        }
    }
    
    func unmount(volume: Volume) {
        DispatchQueue.main.async { self.busyVolumeIdentifier = volume.id }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runShell("diskutil unmount \(volume.id)")
            DispatchQueue.main.async {
                if let error = result.error, !error.isEmpty {
                    let friendlyMessage = self.parseDiskUtilError(error, for: volume.name, operation: .unmount)
                    self.operationError = AppAlert(title: NSLocalizedString("Unmount Failed", comment: "Alert title"), message: friendlyMessage)
                }
                self.busyVolumeIdentifier = nil
                self.refreshDrives(qos: .userInitiated)
            }
        }
    }

    // MARK: - Parsing and Data Creation Helpers

    private func parseDisks(from plist: [String: Any]) -> [PhysicalDisk] {
        guard let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        let ignoredDiskIDs = PersistenceManager.shared.ignoredDisks
        var newDisks: [PhysicalDisk] = []

        for diskData in allDisksAndPartitions {
            guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
            
            if ignoredDiskIDs.contains(physicalIdentifier) {
                continue
            }
            
            let infoPlist = getInfoForDisk(for: diskData["DeviceIdentifier"] as? String ?? "")
            if (infoPlist?["Internal"] as? Bool) ?? false {
                continue
            }

            let isContainer = diskData["Content"] as? String == "Apple_APFS_Container"
            if isContainer {
                continue
            }
            
            guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
            
            var allVolumes: [Volume] = []
            
            if let partitions = diskData["Partitions"] as? [[String: Any]] {
                for partitionData in partitions {
                    if let contentType = partitionData["Content"] as? String, contentType == "Apple_APFS" {
                        let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
                        if let container = findAPFSContainer(forStore: storeID, in: allDisksAndPartitions),
                           let apfsVolumes = container["APFSVolumes"] as? [[String: Any]] {
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
                let connectionInfo = getConnectionInfo(from: infoPlist)
                let diskName = infoPlist?["IORegistryEntryName"] as? String ?? infoPlist?["MediaName"] as? String ?? allVolumes.first(where: { $0.category == .user })?.name
                let (totalSizeStr, freeSpaceStr, usagePercentage) = calculateParentDiskStats(totalBytes: diskData["Size"] as? Int64 ?? 0, volumes: allVolumes)

                let physicalDisk = PhysicalDisk(id: physicalIdentifier, connectionType: connectionInfo.type, volumes: allVolumes, name: diskName, totalSize: totalSizeStr, freeSpace: freeSpaceStr, usagePercentage: usagePercentage, type: connectionInfo.diskType)
                newDisks.append(physicalDisk)
            }
        }
        return newDisks.sorted {
            if $0.type == .physical && $1.type == .diskImage { return true }
            if $0.type == .diskImage && $1.type == .physical { return false }
            return ($0.name ?? "") < ($1.name ?? "")
        }
    }

    private func getInfoForDisk(for identifier: String) -> [String: Any]? {
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
    
    private func calculateParentDiskStats(totalBytes: Int64, volumes: [Volume]) -> (String?, String?, Double?) {
        var usedBytes: Int64 = 0
        let hasMountedVolume = volumes.contains { $0.isMounted }
        
        for volume in volumes {
            if volume.isMounted, let mountPoint = volume.mountPoint, let attributes = getFileSystemAttributes(for: mountPoint) {
                usedBytes += (attributes.total - attributes.free)
            }
        }
        
        if hasMountedVolume && totalBytes > 0 {
            let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]; formatter.countStyle = .file
            let totalSizeStr = formatter.string(fromByteCount: totalBytes)
            let freeSpaceStr = formatter.string(fromByteCount: totalBytes - usedBytes)
            let usagePercentage = Double(usedBytes) / Double(totalBytes)
            return (totalSizeStr, freeSpaceStr, usagePercentage)
        }
        return (nil, nil, nil)
    }

    private func createVolume(from volumeData: [String: Any]) -> Volume? {
        guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String,
              let volumeName = volumeData["VolumeName"] as? String else { return nil }
        
        let isProtected = PersistenceManager.shared.protectedVolumes.contains(deviceIdentifier)
        
        var isVirtualDisk = false
        if let session = DASessionCreate(kCFAllocatorDefault) {
            if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, deviceIdentifier) {
                if let desc = DADiskCopyDescription(disk) {
                    let description = desc as! [String: Any]
                    if description[kDADiskDescriptionDeviceModelKey as String] as? String == "Disk Image" {
                        isVirtualDisk = true
                    }
                }
            }
        }
        
        let contentType = volumeData["Content"] as? String
        let category: DriveCategory = (contentType == "EFI" && isVirtualDisk) ? .system : .user
        let isMounted = volumeData["MountPoint"] != nil
        let mountPoint = volumeData["MountPoint"] as? String
        let fileSystemType = contentType ?? (volumeData["FilesystemName"] as? String) ?? "Unknown"
        var freeSpaceStr: String?, totalSizeStr: String?, usagePercentage: Double?

        if isMounted, let mountPoint = mountPoint, let attributes = getFileSystemAttributes(for: mountPoint) {
            let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]; formatter.countStyle = .file
            freeSpaceStr = formatter.string(fromByteCount: attributes.free)
            totalSizeStr = formatter.string(fromByteCount: attributes.total)
            if attributes.total > 0 { usagePercentage = Double(attributes.total - attributes.free) / Double(attributes.total) }
        }
        
        return Volume(id: deviceIdentifier, name: volumeName, isMounted: isMounted, mountPoint: mountPoint,
                      freeSpace: freeSpaceStr, totalSize: totalSizeStr, fileSystemType: fileSystemType,
                      usagePercentage: usagePercentage, category: category, isProtected: isProtected)
    }

    private func getConnectionInfo(from infoPlist: [String: Any]?) -> (type: String, diskType: PhysicalDiskType) {
        let defaultType = NSLocalizedString("Unknown", comment: "Unknown connection type")
        guard let info = infoPlist else { return (defaultType, .physical) }
        if info["VirtualOrPhysical"] as? String == "Virtual" {
            return (NSLocalizedString("Disk Image", comment: "Disk Image"), .diskImage)
        }
        let connectionType = info["BusProtocol"] as? String ?? defaultType
        return (connectionType, .physical)
    }
    
    // MARK: - Error Parsing
    
    private enum DiskOperation { case mount, unmount, eject }

    private func parseDiskUtilError(_ rawError: String, for name: String, operation: DiskOperation) -> String {
        let lowercasedError = rawError.lowercased()
        
        if operation == .mount && name.uppercased() == "EFI" {
            let formatString = NSLocalizedString("The “EFI” partition cannot be mounted directly. This is a special system partition and this behavior is normal.", comment: "User-friendly error for a failed EFI mount.")
            return String(format: formatString, name)
        }

        if lowercasedError.contains("at least one volume could not be unmounted") {
            let formatString = NSLocalizedString("Failed to eject “%@” because one of its volumes is busy or in use.", comment: "User-friendly error for a partial eject failure. %@ is disk name.")
            return String(format: formatString, name)
        }

        if lowercasedError.contains("busy") || lowercasedError.contains("in use") {
            let actionString: String
            switch operation {
            case .unmount: actionString = NSLocalizedString("unmount", comment: "verb")
            case .eject: actionString = NSLocalizedString("eject", comment: "verb")
            case .mount: actionString = NSLocalizedString("mount", comment: "verb")
            }
            let formatString = NSLocalizedString("Failed to %@ “%@” because it is currently in use by another application.", comment: "Error message")
            return String(format: formatString, actionString, name)
        }
        
        let genericFormatString = NSLocalizedString("An unknown error occurred while trying to %@ “%@”.", comment: "Error message")
        let actionString: String
        switch operation {
        case .mount: actionString = "mount"
        case .unmount: actionString = "unmount"
        case .eject: actionString = "eject"
        }
        
        return "\(String(format: genericFormatString, actionString, name))\n\nDetails:\n\(rawError)"
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