//  Created by homielab.com

import Foundation

class NetworkMountManager: ObservableObject {
  static let shared = NetworkMountManager()

  @Published var mountedShareIDs: Set<UUID> = []
  @Published var manuallyConnectedShares: [NetworkShare] = []
  
  private var manualSharesDictionary: [String: NetworkShare] = [:]

  private init() {
    // Initial check
    refreshMountStatus()
  }

  func refreshMountStatus() {
    DispatchQueue.global(qos: .background).async { [weak self] in
      guard let self = self else { return }
      let result = runShell("mount")
      guard let output = result.output else { return }

      let parsedData = self.parseMountedShares(from: output)

      DispatchQueue.main.async {
        self.mountedShareIDs = parsedData.mountedUUIDs
        self.manuallyConnectedShares = parsedData.manualShares
      }
    }
  }

  private func parseMountedShares(from mountOutput: String) -> (mountedUUIDs: Set<UUID>, manualShares: [NetworkShare]) {
    var mountedUUIDs = Set<UUID>()
    var currentManualShareMountPoints = Set<String>()
    var manualShares = [NetworkShare]()
    
    let shares = PersistenceManager.shared.networkShares
    let lines = mountOutput.components(separatedBy: .newlines)
    
    for line in lines {
      if line.contains("smbfs") {
        let parts = line.components(separatedBy: " on ")
        if parts.count >= 2 {
          let source = parts[0].trimmingCharacters(in: .whitespaces)
          let rest = parts[1]
          let mountPoint = rest.components(separatedBy: " (").first ?? ""
          
          let decodedSource = source.removingPercentEncoding ?? source
          let cleanSource = decodedSource.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
          
          var matched = false
          for share in shares {
            let decodedSharePath = share.sharePath.removingPercentEncoding ?? share.sharePath
            let cleanSharePath = decodedSharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let cleanServer = share.server.lowercased()
            
            if cleanSource.contains(cleanServer) && cleanSource.contains(cleanSharePath) {
              if cleanSource.hasSuffix("/\(cleanSharePath)") {
                mountedUUIDs.insert(share.id)
                matched = true
                break
              }
            }
          }
          
          if !matched {
            // It's a manually connected share
            currentManualShareMountPoints.insert(mountPoint)
            
            if let existing = manualSharesDictionary[mountPoint] {
              manualShares.append(existing)
            } else {
              // Parse the source
              var username = ""
              var server = ""
              var sharePath = ""
              
              let urlString = source.replacingOccurrences(of: "//", with: "smb://")
              if let url = URL(string: urlString) {
                username = url.user ?? ""
                server = url.host ?? ""
                sharePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
              } else {
                server = "Unknown"
                sharePath = "Share"
              }
              
              if sharePath.isEmpty {
                sharePath = mountPoint.components(separatedBy: "/").last ?? "Share"
              }
              
              let newShare = NetworkShare(
                id: UUID(),
                name: sharePath,
                server: server,
                sharePath: sharePath,
                username: username,
                mountAtLogin: false,
                customMountPoint: mountPoint
              )
              manualSharesDictionary[mountPoint] = newShare
              manualShares.append(newShare)
            }
          }
        }
      }
    }
    
    // Clean up old manual shares that are no longer mounted
    manualSharesDictionary = manualSharesDictionary.filter { currentManualShareMountPoints.contains($0.key) }
    
    return (mountedUUIDs, manualShares)
  }


  func mount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    let mountPoint = configuredMountPoint(for: share)

    let password = KeychainManager.shared.load(account: share.id.uuidString) ?? ""

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
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain
        && (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileNoSuchFileError)
      {
        completion(
          false,
          "Cannot create mount point at \"\(mountPoint)\".\n\nThis location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/\(share.name)) or leave the Custom Mount Point empty to use the default location."
        )
      } else {
        completion(
          false, "Failed to create mount point at \"\(mountPoint)\": \(error.localizedDescription)")
      }
      return
    }

    // Construct the URL string carefully
    var urlComponents = URLComponents()
    urlComponents.scheme = "smb"
    if !share.username.isEmpty {
      urlComponents.user = share.username
      urlComponents.password = password
    }
    urlComponents.host = share.server
    urlComponents.path = "/\(share.sharePath)"

    guard let url = urlComponents.url else {
      completion(false, "Invalid share configuration")
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let command =
        "/sbin/mount_smbfs -o noowners,nosuid \"\(url.absoluteString)\" \"\(mountPoint)\""
      let result = runShell(command)

      DispatchQueue.main.async {
        self.refreshMountStatus()
        if let error = result.error, !error.isEmpty {
          // Cleanup mount point if empty
          try? FileManager.default.removeItem(atPath: mountPoint)

          let sanitized = self.sanitizeError(error)
          // Detect permission-related mount failures
          let lower = sanitized.lowercased()
          if lower.contains("permission denied") || lower.contains("operation not permitted")
            || lower.contains("not owner")
          {
            completion(
              false,
              "Could not mount \"\(share.name)\" at \"\(mountPoint)\".\n\nThe mount location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/\(share.name)) or leave the Custom Mount Point empty to use the default location."
            )
          } else {
            completion(false, sanitized)
          }
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
          // Error is already sanitized by mount()
          print("Failed to auto-mount \(share.name): \(error ?? "Unknown error")")
        } else {
          print("Successfully auto-mounted \(share.name)")
        }
      }
    }
  }

  func unmount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    let mountPoint = configuredMountPoint(for: share)

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

    return configuredMountPoint(for: share)
  }

  private func configuredMountPoint(for share: NetworkShare) -> String {
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
          let mountPoint = rest.components(separatedBy: " (").first ?? ""
          
          let decodedSource = source.removingPercentEncoding ?? source
          let cleanSource = decodedSource.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
          
          let decodedSharePath = share.sharePath.removingPercentEncoding ?? share.sharePath
          let cleanSharePath = decodedSharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
          let cleanServer = share.server.lowercased()

          if cleanSource.contains(cleanServer) && cleanSource.contains(cleanSharePath) {
            if cleanSource.hasSuffix("/\(cleanSharePath)") {
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

  /// Strips credentials from SMB URLs in error strings to prevent password leaks.
  /// e.g. "smb://user:p%40ss@host/share" → "smb://user:***@host/share"
  private func sanitizeError(_ error: String) -> String {
    // Match smb://user:password@host patterns (password may be URL-encoded)
    let pattern = "(smb://[^:]+:)([^@]+)(@)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return error
    }
    return regex.stringByReplacingMatches(
      in: error,
      range: NSRange(error.startIndex..., in: error),
      withTemplate: "$1***$3"
    )
  }
}
