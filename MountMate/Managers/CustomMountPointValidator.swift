//  Created by homielab.com

import Foundation

/// Checks of the folder a user picks as a volume's custom mount point.
enum CustomMountPointValidator {
  /// Trims surrounding whitespace, expands `~` and, for an absolute path,
  /// collapses `//`, `.` and `..` (`/x/..` becomes `/`).
  static func normalizedPath(_ rawPath: String) -> String {
    let expanded =
      (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return expanded }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
  }

  /// Why the already normalized `path` can never be a mount point (empty,
  /// relative, the root folder, control characters), or nil. Pure: it never
  /// touches the file system, so it is safe for folders on a hung share.
  static func pathRuleError(_ path: String) -> String? {
    guard !path.isEmpty else {
      return NSLocalizedString(
        "Custom Mount Point Empty Path",
        comment: "Custom mount point validation")
    }
    guard path.hasPrefix("/") else {
      return NSLocalizedString(
        "Custom Mount Point Must Be Absolute",
        comment: "Custom mount point validation")
    }
    guard path != "/" else {
      return NSLocalizedString(
        "Custom Mount Point Cannot Be Root",
        comment: "Custom mount point validation")
    }
    // A control character (a line break above all) could end the field in the
    // root-written /etc/fstab rule and start a line of its own.
    if FstabRules.containsUnsafeFstabCharacter(path) {
      return NSLocalizedString(
        "Custom Mount Point Control Characters",
        comment: "Custom mount point validation")
    }
    return nil
  }

  /// Why `rawPath` cannot be used as a custom mount point, or nil if it can.
  /// - Parameter mountedVolumeName: the name of another volume already
  ///   mounted at the (normalized) path, if any.
  static func validationError(
    for rawPath: String, mountedVolumeName: (String) -> String?
  ) -> String? {
    let path = normalizedPath(rawPath)
    if let error = pathRuleError(path) { return error }
    if let mountedVolumeName = mountedVolumeName(path) {
      return String(
        format: NSLocalizedString(
          "Custom Mount Point In Use",
          comment: "Custom mount point validation"), mountedVolumeName)
    }

    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      return NSLocalizedString(
        "Custom Mount Point Must Be Folder",
        comment: "Custom mount point validation")
    }

    return nil
  }

  /// What checking a folder chosen as a custom mount point found.
  enum Check {
    case invalid(String)
    case directory(exists: Bool, isDirectory: Bool, isEmpty: Bool)
    case inspectFailed(String)
    /// The file system did not answer within the timeout (a hung network share).
    case timedOut
  }

  /// Validates and inspects `rawPath` off the main thread and calls
  /// `completion` on the main thread, after `timeout` at the latest. The folder
  /// may sit on a network share that no longer answers.
  static func check(
    _ rawPath: String, excluding volume: Volume? = nil, timeout: TimeInterval = 2,
    completion: @escaping (Check) -> Void
  ) {
    runWithTimeout(
      timeout,
      work: { () -> Check in
        if let error = validationError(for: rawPath, excluding: volume) {
          return .invalid(error)
        }
        do {
          let state = try inspectDirectory(at: rawPath)
          return .directory(
            exists: state.exists, isDirectory: state.isDirectory, isEmpty: state.isEmpty)
        } catch {
          return .inspectFailed(error.localizedDescription)
        }
      },
      completion: { completion($0 ?? .timedOut) })
  }

  /// Runs `work` on a background queue; `completion` runs once on the main
  /// thread with its result, or with nil when it takes longer than `timeout`
  /// (the work then finishes unobserved).
  static func runWithTimeout<T: Sendable>(
    _ timeout: TimeInterval, work: @escaping @Sendable () -> T,
    completion: @escaping @Sendable (T?) -> Void
  ) {
    let lock = NSLock()
    nonisolated(unsafe) var finished = false
    let finish: @Sendable (T?) -> Void = { value in
      let isFirst = lock.withLock { () -> Bool in
        defer { finished = true }
        return !finished
      }
      guard isFirst else { return }
      DispatchQueue.main.async { completion(value) }
    }
    DispatchQueue.global(qos: .userInitiated).async { finish(work()) }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
  }

  static func inspectDirectory(at rawPath: String) throws -> (
    exists: Bool, isDirectory: Bool, isEmpty: Bool
  ) {
    let path = normalizedPath(rawPath)
    var isDirectory = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    guard exists else { return (false, false, true) }
    guard isDirectory.boolValue else { return (true, false, false) }

    let contents = try FileManager.default.contentsOfDirectory(atPath: path)
    return (true, true, contents.isEmpty)
  }

  /// `validationError(for:mountedVolumeName:)` looking at the volumes mounted
  /// right now (other than `volume`).
  static func validationError(for rawPath: String, excluding volume: Volume?) -> String? {
    validationError(for: rawPath) { path in
      mountedVolumeName(at: path, excluding: volume)
    }
  }

  static func mountedVolumeName(at rawPath: String, excluding volume: Volume? = nil) -> String? {
    let targetPath = URL(fileURLWithPath: normalizedPath(rawPath)).standardizedFileURL
      .path
    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey]
    let mountedURLs =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(keys), options: []) ?? []

    for url in mountedURLs {
      guard url.standardizedFileURL.path == targetPath else { continue }

      if let volume,
        let currentMountPoint = volume.mountPoint,
        URL(fileURLWithPath: currentMountPoint).standardizedFileURL.path == targetPath
      {
        continue
      }

      let values = try? url.resourceValues(forKeys: keys)
      if let volume, values?.volumeUUIDString == volume.id {
        continue
      }

      return values?.volumeName ?? url.lastPathComponent
    }

    return nil
  }
}
