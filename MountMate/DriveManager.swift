//
//  Created by homielab
//

import SwiftUI
import Foundation

class DriveManager: ObservableObject {
    @Published var drives: [Drive] = []
    @Published var busyDriveIdentifier: String? = nil
    @Published var isUnmountingAll = false
    
    init() {
        setupDiskChangeObservers()
        refreshDrives()
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func refreshDrives() {
        DispatchQueue.global(qos: .background).async {
            let output = runShell("diskutil list -plist external")
            var newDrives: [Drive] = []
            
            if let data = output?.data(using: .utf8) {
                do {
                    if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                       let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] {
                        
                        for disk in allDisksAndPartitions {
                            var volumesToParse: [[String: Any]] = []
                            var isAPFSContainer = false

                            if let partitions = disk["Partitions"] as? [[String: Any]] {
                                volumesToParse.append(contentsOf: partitions)
                            }
                            
                            if let apfsVolumes = disk["APFSVolumes"] as? [[String: Any]] {
                                volumesToParse.append(contentsOf: apfsVolumes)
                                isAPFSContainer = true
                            }
                            
                            for volumeData in volumesToParse {
                                guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String,
                                      let volumeName = volumeData["VolumeName"] as? String else {
                                    continue
                                }
                                
                                if volumeName.contains("Simulator") {
                                    print("Skipping Simulator disk: \(volumeName)")
                                    continue
                                }
                                
                                let contentType = volumeData["Content"] as? String
                                let driveType: DriveType
                                if contentType == "EFI" || volumeName.contains("Simulator") {
                                    driveType = .systemPartition
                                } else {
                                    driveType = .userVolume
                                }
                                
                                let isMounted = volumeData["MountPoint"] != nil
                                let mountPoint = volumeData["MountPoint"] as? String
                                
                                var fileSystemType: String
                                if isAPFSContainer {
                                    fileSystemType = "APFS"
                                } else {
                                    fileSystemType = contentType ?? (volumeData["FilesystemName"] as? String) ?? NSLocalizedString("Unknown", comment: "Unknown file system type")
                                }
                                
                                var freeSpaceStr: String?
                                var totalSizeStr: String?
                                var usagePercentage: Double?
                                
                                if isMounted, let mountPoint = mountPoint, let attributes = self.getFileSystemAttributes(for: mountPoint) {
                                    let formatter = ByteCountFormatter()
                                    formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
                                    formatter.countStyle = .file
                                    
                                    freeSpaceStr = formatter.string(fromByteCount: attributes.free)
                                    totalSizeStr = formatter.string(fromByteCount: attributes.total)
                                    
                                    if attributes.total > 0 {
                                        let usedSpace = attributes.total - attributes.free
                                        usagePercentage = Double(usedSpace) / Double(attributes.total)
                                    }
                                }
                                
                                let drive = Drive(
                                    id: deviceIdentifier,
                                    name: volumeName,
                                    deviceIdentifier: deviceIdentifier,
                                    isMounted: isMounted,
                                    mountPoint: mountPoint,
                                    freeSpace: freeSpaceStr,
                                    totalSize: totalSizeStr,
                                    fileSystemType: fileSystemType,
                                    usagePercentage: usagePercentage,
                                    type: driveType // Assign the type
                                )
                                newDrives.append(drive)
                            }
                        }
                    }
                } catch {
                    print("Error parsing diskutil plist: \(error)")
                }
            }
            
            let sortedDrives = newDrives.sorted {
                // Sort by type first (user volumes before system partitions)
                if $0.type == .userVolume && $1.type == .systemPartition { return true }
                if $0.type == .systemPartition && $1.type == .userVolume { return false }
                // Then sort alphabetically by name
                return $0.name < $1.name
            }
            
            DispatchQueue.main.async {
                self.drives = sortedDrives
                self.busyDriveIdentifier = nil
                self.isUnmountingAll = false
            }
        }
    }

    func unmountAllDrives() {
        // Instantly update the UI to show the global loading state
        DispatchQueue.main.async {
            self.isUnmountingAll = true
        }
        
        // Run the unmount commands on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            // Filter for only mounted drives that are user volumes
            let drivesToUnmount = self.drives.filter { $0.isMounted && $0.type == .userVolume }
            
            print("Attempting to unmount \(drivesToUnmount.count) drives.")
            
            for drive in drivesToUnmount {
                _ = runShell("diskutil unmount \(drive.deviceIdentifier)")
            }
            
            // After attempting to unmount, refresh the list
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { // A slightly longer delay
                self.refreshDrives()
            }
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
        
        // Add observer for when a volume is mounted
        notificationCenter.addObserver(
            self,
            selector: #selector(handleDiskNotification),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        
        // Add observer for when a volume is unmounted
        notificationCenter.addObserver(
            self,
            selector: #selector(handleDiskNotification),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    @objc private func handleDiskNotification(notification: NSNotification) {
        if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
             print("Disk notification received for volume: \(volumeURL.lastPathComponent). Refreshing list.")
        } else {
            print("Disk notification received. Refreshing list.")
        }
        
        // Wait just a moment before refreshing to ensure the system
        // has finalized the mount/unmount operation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.refreshDrives()
        }
    }
}
