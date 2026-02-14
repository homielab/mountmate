//  Created by homielab.com

import Foundation

class NetworkMountManager: ObservableObject {
  static let shared = NetworkMountManager()
  
  @Published var mountedShareIDs: Set<UUID> = []
  
  private init() {
      // Initial check
      refreshMountStatus()
  }

  func refreshMountStatus() {
    DispatchQueue.global(qos: .background).async { [weak self] in
        guard let self = self else { return }
        let result = runShell("mount")
        guard let output = result.output else { return }
        
        let mountedShares = self.parseMountedShares(from: output)
        
        DispatchQueue.main.async {
            self.mountedShareIDs = mountedShares
        }
    }
  }

  private func parseMountedShares(from mountOutput: String) -> Set<UUID> {
      var mountedUUIDs = Set<UUID>()
      let shares = PersistenceManager.shared.networkShares
      
      // Optimization: Check if we can match existing shares to the mount output
      // This is slightly complex because we need to match the share configuration to the mount output line.
      // We can reuse the logic from `findExistingMountPoint` but applied in batch.
      
      for share in shares {
          if self.isShareMounted(share, in: mountOutput) {
              mountedUUIDs.insert(share.id)
          }
      }
      return mountedUUIDs
  }
    
  private func isShareMounted(_ share: NetworkShare, in mountOutput: String) -> Bool {
      let lines = mountOutput.components(separatedBy: .newlines)
      for line in lines {
        if line.contains("smbfs") {
          let parts = line.components(separatedBy: " on ")
          if parts.count >= 2 {
            let source = parts[0].trimmingCharacters(in: .whitespaces)
            if source.contains(share.server) && source.contains(share.sharePath) {
               if source.hasSuffix("/\(share.sharePath)") {
                 return true
               }
            }
          }
        }
      }
      return false
  }

  func mount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    let mountPoint: String
    if let customPath = share.customMountPoint, !customPath.isEmpty {
      // Expand tilde if present
      let expandedPath = (customPath as NSString).expandingTildeInPath

      // If path is not absolute, assume relative to home directory
      if !expandedPath.hasPrefix("/") {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        mountPoint = "\(homeDir)/\(expandedPath)"
      } else {
        mountPoint = expandedPath
      }
    } else {
      let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
      let mountsDir = "\(homeDir)/mountmate"
      mountPoint = "\(mountsDir)/\(share.name)"

      // Ensure ~/mountmate exists
      if !FileManager.default.fileExists(atPath: mountsDir) {
        try? FileManager.default.createDirectory(
          atPath: mountsDir, withIntermediateDirectories: true)
      }
    }

    let password = KeychainManager.shared.load(account: share.id.uuidString) ?? ""

    // Construct URL: smb://username:password@server/sharePath
    // Note: Special characters in password need to be URL encoded if we were passing it in the URL directly,
    // but mount_smb handles it differently.
    // However, `mount_smb` is often easier to use with the URL format.

    // A safer way is to use `open` with the URL, but `mount_smb` gives us more control (like creating the directory).
    // Check if already mounted (either at our target path or elsewhere)
    if let existingMount = findExistingMountPoint(for: share) {
      print("Share \(share.name) is already mounted at \(existingMount)")
      self.refreshMountStatus()
      completion(true, nil)
      return
    }

    // Also check our specific target path just in case
    if isMounted(at: mountPoint) {
      self.refreshMountStatus()
      completion(true, nil)
      return
    }

    // Let's try creating the directory first.
    do {
      if !FileManager.default.fileExists(atPath: mountPoint) {
        try FileManager.default.createDirectory(
          atPath: mountPoint, withIntermediateDirectories: true)
      }
    } catch {
      completion(false, "Failed to create mount point: \(error.localizedDescription)")
      return
    }

    // Construct the URL string carefully
    var urlComponents = URLComponents()
    urlComponents.scheme = "smb"
    urlComponents.user = share.username
    urlComponents.password = password
    urlComponents.host = share.server
    urlComponents.path = "/\(share.sharePath)"

    guard let url = urlComponents.url else {
      completion(false, "Invalid share configuration")
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      // Use mount_smbfs
      // mount_smbfs //user:password@server/share /Volumes/mountPoint

      let command = "/sbin/mount_smbfs \"\(url.absoluteString)\" \"\(mountPoint)\""
      let result = runShell(command)

      DispatchQueue.main.async {
        self.refreshMountStatus()
        if let error = result.error, !error.isEmpty {
          // Cleanup mount point if empty
          try? FileManager.default.removeItem(atPath: mountPoint)
          completion(false, error)
        } else {
          completion(true, nil)
        }
      }
    }
  }

  func mountAllAutoShares() {
    let shares = PersistenceManager.shared.networkShares.filter { $0.mountAtLogin }
    for share in shares {
      mount(share: share) { success, error in
        if !success {
          print("Failed to auto-mount \(share.name): \(error ?? "Unknown error")")
        } else {
          print("Successfully auto-mounted \(share.name)")
        }
      }
    }
  }

  func unmount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    let mountPoint: String
    if let customPath = share.customMountPoint, !customPath.isEmpty {
      let expandedPath = (customPath as NSString).expandingTildeInPath
      if !expandedPath.hasPrefix("/") {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        mountPoint = "\(homeDir)/\(expandedPath)"
      } else {
        mountPoint = expandedPath
      }
    } else {
      let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
      let mountsDir = "\(homeDir)/mountmate"
      mountPoint = "\(mountsDir)/\(share.name)"
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let result = runShell("umount \"\(mountPoint)\"")

      DispatchQueue.main.async {
        self.refreshMountStatus()
        if let error = result.error, !error.isEmpty {
          completion(false, error)
        } else {
          completion(true, nil)
        }
      }
    }
  }

  func isMounted(share: NetworkShare) -> Bool {
      return mountedShareIDs.contains(share.id)
  }

  func getMountPoint(for share: NetworkShare) -> String {
    // If it's already mounted somewhere, return that path
    if let existingPath = findExistingMountPoint(for: share) {
      return existingPath
    }

    // Otherwise return the configured path
    if let customPath = share.customMountPoint, !customPath.isEmpty {
      let expandedPath = (customPath as NSString).expandingTildeInPath
      if !expandedPath.hasPrefix("/") {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/\(expandedPath)"
      } else {
        return expandedPath
      }
    } else {
      let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
      let mountsDir = "\(homeDir)/mountmate"
      return "\(mountsDir)/\(share.name)"
    }
  }

  private func findExistingMountPoint(for share: NetworkShare) -> String? {
    // Run mount command to get list of mounts
    let result = runShell("mount")
    guard let output = result.output else { return nil }

    // Expected format: //username@server/share on /path (smbfs, ...)
    // Or: //server/share on /path (smbfs, ...)

    // We construct search patterns.
    // Note: mount output usually has the server and path in lowercase? Not necessarily.
    // Let's try to match case-insensitive for the server/share part.

    let lines = output.components(separatedBy: .newlines)
    for line in lines {
      if line.contains("smbfs") {
        // Parse the line
        // Example: //meo@192.168.1.100/public on /Volumes/public (smbfs, ...)
        let parts = line.components(separatedBy: " on ")
        if parts.count >= 2 {
          let source = parts[0].trimmingCharacters(in: .whitespaces)
          let rest = parts[1]

          // Extract mount point from 'rest' (everything before " (")
          let mountPoint = rest.components(separatedBy: " (").first ?? ""

          // Check if source matches our share
          // Source format: //user@host/path

          if source.contains(share.server) && source.contains(share.sharePath) {
            // Basic check: contains server and share path.
            // This might be too loose if you have shares with similar names, but it's a good start.
            // Let's be a bit stricter.

            // Check if it ends with /sharePath
            if source.hasSuffix("/\(share.sharePath)") {
              return mountPoint
            }
          }
        }
      }
    }
    return nil
  }

  private func isMounted(at path: String) -> Bool {
    var fileStat = stat()
    if stat(path, &fileStat) != 0 {
      return false
    }

    var parentStat = stat()
    let parentPath = (path as NSString).deletingLastPathComponent
    if stat(parentPath, &parentStat) != 0 {
      return false
    }

    // If device IDs differ, it's a mount point
    return fileStat.st_dev != parentStat.st_dev
  }
}
