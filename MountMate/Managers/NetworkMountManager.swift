//  Created by homielab.com

import Foundation

/// A network mount reported by `/sbin/mount`, independent of protocol.
struct MountedNetworkShare {
  let source: String
  let mountPoint: String
  let shareProtocol: ShareProtocol

  init?(mountOutputLine: String) {
    // Match the filesystem name as a parenthesized option (e.g. "(smbfs,")
    // so it is never confused with a mount point that happens to contain
    // the same word.
    guard let openIndex = mountOutputLine.lastIndex(of: "("),
      let closeIndex = mountOutputLine[openIndex...].firstIndex(of: ")")
    else { return nil }

    let options = mountOutputLine[mountOutputLine.index(after: openIndex)..<closeIndex]
    let fileSystem =
      options
      .split(separator: ",")
      .first?
      .trimmingCharacters(in: .whitespaces)
      .lowercased() ?? ""

    guard let shareProtocol = ShareProtocol.from(mountFilesystemName: fileSystem) else {
      return nil
    }

    let mountPart = String(mountOutputLine[..<openIndex])
    let parts = mountPart.components(separatedBy: " on ")
    guard parts.count >= 2 else { return nil }

    source = parts[0].trimmingCharacters(in: .whitespaces)
    mountPoint = parts[1].trimmingCharacters(in: .whitespaces)
    self.shareProtocol = shareProtocol
  }

  func matches(_ share: NetworkShare) -> Bool {
    let decodedSource = source.removingPercentEncoding ?? source
    let cleanSource =
      decodedSource
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
    let decodedSharePath = share.sharePath.removingPercentEncoding ?? share.sharePath
    let cleanSharePath =
      decodedSharePath
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .lowercased()
    let cleanServer = share.server.lowercased()

    return cleanSource.contains(cleanServer)
      && cleanSource.contains(cleanSharePath)
      && cleanSource.hasSuffix("/\(cleanSharePath)")
  }
}

class NetworkMountManager: ObservableObject {
  static let shared = NetworkMountManager()

  @Published var mountedShareIDs: Set<UUID> = []
  @Published var manuallyConnectedShares: [NetworkShare] = []
  @Published var isUnmountingManualShares = false

  private var manualSharesDictionary: [String: NetworkShare] = [:]

  private init() {
    // Initial check
    refreshMountStatus()
  }

  func refreshMountStatus(completion: (() -> Void)? = nil) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { completion?() }
        return
      }
      let result = runProcess(executable: "/sbin/mount", arguments: [])
      guard result.succeeded, !result.stdout.isEmpty else {
        DispatchQueue.main.async { completion?() }
        return
      }
      let output = result.stdout

      let parsedData = self.parseMountedShares(from: output)

      DispatchQueue.main.async {
        self.mountedShareIDs = parsedData.mountedUUIDs
        self.manuallyConnectedShares = parsedData.manualShares
        completion?()
      }
    }
  }

  /// Returns the currently mounted network shares that are not already saved in
  /// MountMate. Refreshing first keeps the result useful when Settings has been
  /// open for a while.
  func discoverManuallyMountedShares(completion: @escaping ([NetworkShare]) -> Void) {
    refreshMountStatus { [weak self] in
      completion(self?.manuallyConnectedShares ?? [])
    }
  }

  /// Resolves a Finder URL dropped anywhere inside a mounted share back to its
  /// network share.
  func manuallyMountedShare(containing url: URL) -> NetworkShare? {
    let droppedPath = url.standardizedFileURL.path
    return manuallyConnectedShares.first { share in
      guard let mountPoint = share.customMountPoint else { return false }
      let mountedPath = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
      return droppedPath == mountedPath || droppedPath.hasPrefix(mountedPath + "/")
    }
  }

  private func parseMountedShares(from mountOutput: String) -> (
    mountedUUIDs: Set<UUID>, manualShares: [NetworkShare]
  ) {
    var mountedUUIDs = Set<UUID>()
    var currentManualShareMountPoints = Set<String>()
    var manualShares = [NetworkShare]()

    let shares = PersistenceManager.shared.networkShares
    let mountedShares = mountOutput.components(separatedBy: .newlines).compactMap {
      MountedNetworkShare(mountOutputLine: $0)
    }

    for mountedShare in mountedShares {
      if let savedShare = shares.first(where: { mountedShare.matches($0) }) {
        mountedUUIDs.insert(savedShare.id)
      } else {
        // It's a manually connected share
        currentManualShareMountPoints.insert(mountedShare.mountPoint)

        if let existing = manualSharesDictionary[mountedShare.mountPoint] {
          manualShares.append(existing)
        } else {
          // Parse the source
          var username = ""
          var server = ""
          var sharePath = ""

          switch mountedShare.shareProtocol {
          case .nfs:
            // NFS sources look like `server:/export/path`.
            let withoutSlashes = mountedShare.source
              .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = withoutSlashes.components(separatedBy: ":")
            server = components.first ?? ""
            sharePath = components.dropFirst().joined(separator: ":")
              .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          default:
            let urlString = mountedShare.source.replacingOccurrences(
              of: "//", with: "\(mountedShare.shareProtocol.urlScheme)://")
            if let url = URL(string: urlString) {
              username = url.user ?? ""
              server = url.host ?? ""
              sharePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
              server = "Unknown"
              sharePath = "Share"
            }
          }

          if sharePath.isEmpty {
            sharePath = mountedShare.mountPoint.components(separatedBy: "/").last ?? "Share"
          }

          let newShare = NetworkShare(
            id: UUID(),
            name: sharePath,
            server: server,
            sharePath: sharePath,
            username: username,
            mountAtLogin: false,
            keepMounted: false,
            shareProtocol: mountedShare.shareProtocol,
            customMountPoint: mountedShare.mountPoint
          )
          manualSharesDictionary[mountedShare.mountPoint] = newShare
          manualShares.append(newShare)
        }
      }
    }

    // Clean up old manual shares that are no longer mounted
    manualSharesDictionary = manualSharesDictionary.filter {
      currentManualShareMountPoints.contains($0.key)
    }

    return (mountedUUIDs, manualShares)
  }

  func mount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    let mountPoint = configuredMountPoint(for: share)

    let password = KeychainManager.shared.load(account: share.id.uuidString) ?? ""

    // An explicit (or automatic) mount clears any user-intent suppression and
    // retry state so keep-alive tracking restarts cleanly.
    KeepAliveManager.shared.resume(shareID: share.id)

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

    guard let url = connectionURL(for: share, password: password) else {
      completion(false, "Invalid share configuration")
      return
    }

    let (executable, arguments) = mountCommand(
      for: share, url: url.absoluteString, mountPoint: mountPoint)

    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(executable: executable, arguments: arguments)

      DispatchQueue.main.async {
        if !result.succeeded {
          // Cleanup mount point if empty
          try? FileManager.default.removeItem(atPath: mountPoint)

          let rawError =
            result.stderr.isEmpty
            ? "\(executable) exited with code \(result.exitCode ?? -1)."
            : result.stderr
          let sanitized = self.sanitizeError(rawError)
          // Detect permission-related mount failures
          let lower = sanitized.lowercased()
          if lower.contains("permission denied") || lower.contains("operation not permitted")
            || lower.contains("not owner")
          {
            self.refreshMountStatus {
              completion(
                false,
                "Could not mount \"\(share.name)\" at \"\(mountPoint)\".\n\nThe mount location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/\(share.name)) or leave the Custom Mount Point empty to use the default location."
              )
            }
          } else {
            self.refreshMountStatus {
              completion(false, sanitized)
            }
          }
        } else {
          self.refreshMountStatus {
            completion(true, nil)
          }
        }
      }
    }
  }

  /// Builds the protocol-specific connection URL for a share.
  ///
  /// - SMB: `smb://user:pass@server/share`
  /// - AFP: `afp://user:pass@server/share`
  /// - NFS: `server:/export/path` (credentials do not apply)
  func connectionURL(for share: NetworkShare, password: String) -> URL? {
    if share.shareProtocol == .nfs {
      var components = URLComponents()
      components.scheme = "nfs"
      components.host = share.server
      components.path = "/\(share.sharePath)"
      return components.url
    }

    var urlComponents = URLComponents()
    urlComponents.scheme = share.shareProtocol.urlScheme
    if !share.username.isEmpty, share.shareProtocol.supportsUserCredentials {
      urlComponents.user = share.username
      urlComponents.password = password
    }
    urlComponents.host = share.server
    urlComponents.path = "/\(share.sharePath)"

    return urlComponents.url
  }

  /// Returns the protocol-specific mount executable and arguments.
  private func mountCommand(for share: NetworkShare, url: String, mountPoint: String) -> (
    executable: String, arguments: [String]
  ) {
    switch share.shareProtocol {
    case .smb:
      return ("/sbin/mount_smbfs", ["-o", "noowners,nosuid", url, mountPoint])
    case .nfs:
      // mount_nfs expects the canonical `server:/export` form.
      let exportPath = "/" + share.sharePath.trimmingCharacters(
        in: CharacterSet(charactersIn: "/"))
      return ("/sbin/mount_nfs", ["-o", "resvport", "\(share.server):\(exportPath)", mountPoint])
    case .afp:
      // No `-i`: credentials are embedded in the URL, and an interactive
      // prompt would block the mount.
      return ("/sbin/mount_afp", [url, mountPoint])
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

  /// Unmounts and immediately mounts a share again so the connection is
  /// re-established over the current network path. Used after network
  /// interface changes when the stale mount still exists.
  func forceRemount(share: NetworkShare, completion: (() -> Void)? = nil) {
    let mountPoint = configuredMountPoint(for: share)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      _ = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
      DispatchQueue.main.async {
        self?.mount(share: share) { _, _ in
          completion?()
        }
      }
    }
  }

  /// Marks a share as intentionally unmounted by the user so the keep-alive
  /// layer does not fight that decision. Cleared on the next explicit mount.
  func markShareUnmountedByUser(_ share: NetworkShare) {
    KeepAliveManager.shared.suppress(shareID: share.id)
  }

  func unmount(share: NetworkShare, completion: @escaping (Bool, String?) -> Void) {
    let mountPoint = configuredMountPoint(for: share)

    DispatchQueue.global(qos: .userInitiated).async {
      let result = runProcess(executable: "/sbin/umount", arguments: [mountPoint])

      DispatchQueue.main.async {
        if !result.succeeded {
          let errMsg =
            result.stderr.isEmpty
            ? "umount exited with code \(result.exitCode ?? -1)."
            : result.stderr
          self.refreshMountStatus {
            completion(false, errMsg)
          }
        } else {
          self.markShareUnmountedByUser(share)
          self.refreshMountStatus {
            completion(true, nil)
          }
        }
      }
    }
  }

  func unmountAllManuallyConnectedShares(completion: @escaping ([String]) -> Void) {
    let shares = manuallyConnectedShares
    guard !shares.isEmpty else {
      completion([])
      return
    }

    isUnmountingManualShares = true
    DispatchQueue.global(qos: .userInitiated).async {
      let failures = shares.compactMap { share -> String? in
        let mountPoint = self.configuredMountPoint(for: share)
        let result = runProcess(executable: "/sbin/umount", arguments: [mountPoint])
        return !result.succeeded ? share.name : nil
      }

      DispatchQueue.main.async {
        self.isUnmountingManualShares = false
        self.refreshMountStatus()
        completion(failures)
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
    let result = runProcess(executable: "/sbin/mount", arguments: [])
    guard result.succeeded, !result.stdout.isEmpty else { return nil }
    let output = result.stdout

    return
      output
      .components(separatedBy: .newlines)
      .compactMap { MountedNetworkShare(mountOutputLine: $0) }
      .first(where: { $0.matches(share) })?
      .mountPoint
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

  /// Strips credentials from network URLs in error strings to prevent password
  /// leaks. e.g. "smb://user:p%40ss@host/share" → "smb://user:***@host/share"
  private func sanitizeError(_ error: String) -> String {
    // Match protocol://user:password@host patterns (password may be URL-encoded)
    let pattern = "((?:smb|afp|nfs)://[^:/@]+:)([^@]+)(@)"
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
