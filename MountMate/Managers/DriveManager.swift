//  Created by homielab.com

import SwiftUI
import Foundation

class DriveManager: ObservableObject {
    @Published var physicalDisks: [PhysicalDisk] = []
    @Published var busyVolumeIdentifier: String? = nil
    @Published var busyEjectingIdentifier: String? = nil
    @Published var isUnmountingAll = false
    
    private var refreshDebounceTimer: Timer?
    
    init() {
        setupDiskChangeObservers()
        refreshDrives()
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        refreshDebounceTimer?.invalidate()
    }

    func refreshDrives() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let externalDisksOutput = runShell("diskutil list -plist external")
            guard let externalData = externalDisksOutput?.data(using: .utf8) else {
                DispatchQueue.main.async { self.physicalDisks = [] }
                return
            }
            
            do {
                if let plist = try PropertyListSerialization.propertyList(from: externalData, options: [], format: nil) as? [String: Any] {
                    let newPhysicalDisks = self.parsePhysicalDisks(from: plist)
                    DispatchQueue.main.async {
                        self.physicalDisks = newPhysicalDisks
                        self.busyVolumeIdentifier = nil
                        self.busyEjectingIdentifier = nil
                        self.isUnmountingAll = false
                    }
                }
            } catch {
                print("Error parsing diskutil list plist: \(error)")
            }
        }
    }
    
    private func parsePhysicalDisks(from plist: [String: Any]?) -> [PhysicalDisk] {
        guard let allDisksAndPartitions = plist?["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var newDisks: [PhysicalDisk] = []

        for diskData in allDisksAndPartitions {
            guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
            
            let connectionType = self.getConnectionType(for: physicalIdentifier)
            let diskType: PhysicalDiskType = connectionType == NSLocalizedString("Disk Image", comment: "Disk Image") ? .diskImage : .physical
            var volumes: [Volume] = []

            var volumesToParse: [[String: Any]] = []
            if let partitions = diskData["Partitions"] as? [[String: Any]] { volumesToParse.append(contentsOf: partitions) }
            if let apfsVolumes = diskData["APFSVolumes"] as? [[String: Any]] { volumesToParse.append(contentsOf: apfsVolumes) }

            for volumeData in volumesToParse {
                if let volume = self.createVolume(from: volumeData) {
                    volumes.append(volume)
                }
            }

            if !volumes.isEmpty {
                let totalBytes = diskData["Size"] as? Int64 ?? 0
                var usedBytes: Int64 = 0
                var hasMountedVolume = false
                
                for volume in volumes {
                    if volume.isMounted, let mountPoint = volume.mountPoint, let attributes = getFileSystemAttributes(for: mountPoint) {
                        let volumeUsed = attributes.total - attributes.free
                        usedBytes += volumeUsed
                        hasMountedVolume = true
                    }
                }
                
                var totalSizeStr: String?, freeSpaceStr: String?, usagePercentage: Double?
                let formatter = ByteCountFormatter(); formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]; formatter.countStyle = .file
                
                if hasMountedVolume && totalBytes > 0 {
                    totalSizeStr = formatter.string(fromByteCount: totalBytes)
                    let freeBytes = totalBytes - usedBytes
                    freeSpaceStr = formatter.string(fromByteCount: freeBytes)
                    usagePercentage = Double(usedBytes) / Double(totalBytes)
                }
                
                let diskName = volumes.first(where: { $0.category == .user })?.name

                let physicalDisk = PhysicalDisk(
                    id: physicalIdentifier,
                    connectionType: connectionType,
                    volumes: volumes,
                    name: diskName,
                    totalSize: totalSizeStr,
                    freeSpace: freeSpaceStr,
                    usagePercentage: usagePercentage,
                    type: diskType
                )
                newDisks.append(physicalDisk)
            }
        }
        return newDisks.sorted {
            if $0.type == .physical && $1.type == .diskImage { return true }
            if $0.type == .diskImage && $1.type == .physical { return false }
            return ($0.name ?? "") < ($1.name ?? "")
        }
    }

    private func createVolume(from volumeData: [String: Any]) -> Volume? {
        guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String,
              let volumeName = volumeData["VolumeName"] as? String else { return nil }
        
        if volumeName.contains("Simulator") { return nil }

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
                      usagePercentage: usagePercentage, category: category)
    }

    private func getConnectionType(for identifier: String) -> String {
        let defaultType = NSLocalizedString("Unknown", comment: "Unknown connection type")
        guard !identifier.isEmpty else { return defaultType }
        let infoOutput = runShell("diskutil info -plist \(identifier)")
        guard let infoData = infoOutput?.data(using: .utf8),
              let infoPlist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else { return defaultType }
        if infoPlist["VirtualOrPhysical"] as? String == "Virtual" { return NSLocalizedString("Disk Image", comment: "Disk Image") }
        return infoPlist["BusProtocol"] as? String ?? defaultType
    }
    
    func unmountAllDrives() {
        DispatchQueue.main.async { self.isUnmountingAll = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let volumesToUnmount = self.physicalDisks.flatMap { $0.volumes }.filter { $0.isMounted && $0.category == .user }
            for volume in volumesToUnmount { _ = runShell("diskutil unmount \(volume.id)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refreshDrives() }
        }
    }
    
    func eject(disk: PhysicalDisk) {
        DispatchQueue.main.async { self.busyEjectingIdentifier = disk.id }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runShell("diskutil eject \(disk.id)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDrives() }
        }
    }

    func mount(volume: Volume) {
        let userInfo = ["deviceIdentifier": volume.id]
        NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
        DispatchQueue.main.async { self.busyVolumeIdentifier = volume.id }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runShell("diskutil mount \(volume.id)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDrives() }
        }
    }
    
    func unmount(volume: Volume) {
        DispatchQueue.main.async { self.busyVolumeIdentifier = volume.id }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runShell("diskutil unmount \(volume.id)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDrives() }
        }
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