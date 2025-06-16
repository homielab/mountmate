//
//  Created by homielab
//

import SwiftUI
import Foundation

class DriveManager: ObservableObject {
    @Published var drives: [Drive] = []
    @Published var busyDriveIdentifier: String? = nil
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
                DispatchQueue.main.async { self.drives = [] }
                return
            }
            
            do {
                if let externalPlist = try PropertyListSerialization.propertyList(from: externalData, options: [], format: nil) as? [String: Any] {
                    let newDrives = self.parseExternalDisks(from: externalPlist)
                    
                    DispatchQueue.main.async {
                        self.drives = newDrives
                        self.busyDriveIdentifier = nil
                        self.isUnmountingAll = false
                    }
                }
            } catch {
                print("Error parsing diskutil list plist: \(error)")
            }
        }
    }
    
    private func parseExternalDisks(from plist: [String: Any]?) -> [Drive] {
        guard let allDisksAndPartitions = plist?["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var newDrives: [Drive] = []

        for disk in allDisksAndPartitions {
            let physicalIdentifier = disk["DeviceIdentifier"] as? String ?? ""
            let connectionType = self.getConnectionType(for: physicalIdentifier)

            var volumesToParse: [[String: Any]] = []
            if let partitions = disk["Partitions"] as? [[String: Any]] { volumesToParse.append(contentsOf: partitions) }
            if let apfsVolumes = disk["APFSVolumes"] as? [[String: Any]] { volumesToParse.append(contentsOf: apfsVolumes) }

            for volumeData in volumesToParse {
                guard let drive = self.createDrive(from: volumeData, connectionType: connectionType) else { continue }
                newDrives.append(drive)
            }
        }
        return newDrives
    }

    private func getConnectionType(for identifier: String) -> String {
        let defaultType = NSLocalizedString("Unknown", comment: "Unknown connection type")
        guard !identifier.isEmpty else { return defaultType }
        
        let infoOutput = runShell("diskutil info -plist \(identifier)")
        
        guard let infoData = infoOutput?.data(using: .utf8),
              let infoPlist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else {
            return defaultType
        }
        
        if infoPlist["VirtualOrPhysical"] as? String == "Virtual" {
            return NSLocalizedString("Disk Image", comment: "Disk Image connection type")
        }
        return infoPlist["BusProtocol"] as? String ?? defaultType
    }

    private func createDrive(from volumeData: [String: Any], connectionType: String) -> Drive? {
        guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String,
              let volumeName = volumeData["VolumeName"] as? String else {
            return nil
        }
        
        let contentType = volumeData["Content"] as? String
        let isVirtualDisk = connectionType == NSLocalizedString("Disk Image", comment: "Disk Image connection type")
        let driveCategory: DriveCategory = (contentType == "EFI" && isVirtualDisk) ? .system : .user

        let isMounted = volumeData["MountPoint"] != nil
        let mountPoint = volumeData["MountPoint"] as? String
        let fileSystemType = contentType ?? (volumeData["FilesystemName"] as? String) ?? "Unknown"
        
        var freeSpaceStr: String?, totalSizeStr: String?, usagePercentage: Double?
        if isMounted, let mountPoint = mountPoint, let attributes = getFileSystemAttributes(for: mountPoint) {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
            formatter.countStyle = .file
            freeSpaceStr = formatter.string(fromByteCount: attributes.free)
            totalSizeStr = formatter.string(fromByteCount: attributes.total)
            if attributes.total > 0 {
                usagePercentage = Double(attributes.total - attributes.free) / Double(attributes.total)
            }
        }
        
        return Drive(
            id: deviceIdentifier, name: volumeName, deviceIdentifier: deviceIdentifier,
            isMounted: isMounted, mountPoint: mountPoint, freeSpace: freeSpaceStr,
            totalSize: totalSizeStr, fileSystemType: fileSystemType,
            usagePercentage: usagePercentage, category: driveCategory,
            connectionType: connectionType
        )
    }
    
    func unmountAllDrives() {
        DispatchQueue.main.async { self.isUnmountingAll = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let drivesToUnmount = self.drives.filter { $0.isMounted && $0.category == .user }
            for drive in drivesToUnmount {
                _ = runShell("diskutil unmount \(drive.deviceIdentifier)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refreshDrives() }
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

    func mount(drive: Drive) {
        let userInfo = ["deviceIdentifier": drive.deviceIdentifier]
        NotificationCenter.default.post(name: .willManuallyMount, object: nil, userInfo: userInfo)
        
        DispatchQueue.main.async { self.busyDriveIdentifier = drive.deviceIdentifier }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runShell("diskutil mount \(drive.deviceIdentifier)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDrives() }
        }
    }
    
    func unmount(drive: Drive) {
        DispatchQueue.main.async { self.busyDriveIdentifier = drive.deviceIdentifier }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runShell("diskutil unmount \(drive.deviceIdentifier)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshDrives() }
        }
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