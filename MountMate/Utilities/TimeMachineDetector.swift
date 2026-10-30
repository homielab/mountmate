//  Created by homielab.com

import Foundation

/// Finds the mounted volumes Time Machine backs up to, beyond what
/// `diskutil` reports (the APFS "Backup" role): HFS+ backup disks keep a
/// `Backups.backupdb` folder at their root, and `tmutil destinationinfo`
/// lists the destinations chosen in System Settings.
enum TimeMachineDetector {
  /// Files at a volume's root that only a Time Machine backup disk has.
  static let rootMarkers = ["Backups.backupdb", ".com.apple.timemachine.supported"]

  /// Whether one of `rootMarkers` exists at `mountPoint`.
  static func hasBackupMarker(
    atMountPoint mountPoint: String, fileExists: (String) -> Bool = FileManager.default.fileExists
  ) -> Bool {
    rootMarkers.contains { fileExists((mountPoint as NSString).appendingPathComponent($0)) }
  }

  /// Mount points of the destinations in `tmutil destinationinfo -X` output.
  static func destinationMountPoints(fromDestinationInfo data: Data) -> Set<String> {
    guard
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let destinations = plist["Destinations"] as? [[String: Any]]
    else { return [] }
    return Set(
      destinations.compactMap { destination in
        (destination["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      })
  }

  /// The local volumes worth checking: those mounted under `/Volumes`.
  static func candidateMountPoints(in entries: [MountEntry]) -> [String] {
    entries.map(\.mountPoint).filter { $0.hasPrefix("/Volumes/") }
  }

  /// The mount points among `mountPoints` with a backup marker. Each check
  /// runs on its own thread and the whole call waits at most `timeout`, so a
  /// slow or hung disk counts as not Time Machine instead of blocking.
  static func markedMountPoints(
    _ mountPoints: [String], timeout: TimeInterval = 1.0,
    check: @escaping @Sendable (String) -> Bool = { hasBackupMarker(atMountPoint: $0) }
  ) -> Set<String> {
    final class Results: @unchecked Sendable {
      let lock = NSLock()
      var found: Set<String> = []
    }
    let results = Results()
    let group = DispatchGroup()
    // At the caller's QoS, as it waits on the checks.
    let queue = DispatchQueue.global(
      qos: DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .utility)
    for mountPoint in mountPoints {
      group.enter()
      queue.async {
        if check(mountPoint) {
          results.lock.lock()
          results.found.insert(mountPoint)
          results.lock.unlock()
        }
        group.leave()
      }
    }
    _ = group.wait(timeout: .now() + timeout)
    results.lock.lock()
    defer { results.lock.unlock() }
    return results.found
  }

  /// The mounted Time Machine volumes among `entries`: root markers plus
  /// `tmutil` destinations (cached until the set of mounted volumes changes).
  static func mountPoints(in entries: [MountEntry]) -> Set<String> {
    let candidates = candidateMountPoints(in: entries)
    guard !candidates.isEmpty else { return [] }
    let destinations = destinationCache.mountPoints(for: Set(candidates)) {
      let result = runProcess(
        executable: "/usr/bin/tmutil", arguments: ["destinationinfo", "-X"], timeout: 3)
      return destinationMountPoints(fromDestinationInfo: Data(result.stdout.utf8))
    }
    return markedMountPoints(candidates).union(destinations.intersection(candidates))
  }

  static let destinationCache = DestinationCache()

  /// `tmutil` destinations, read again only when the mounted volumes change.
  final class DestinationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Set<String>?
    private var value: Set<String> = []

    func mountPoints(for mounted: Set<String>, load: () -> Set<String>) -> Set<String> {
      lock.lock()
      defer { lock.unlock() }
      if key != mounted {
        value = load()
        key = mounted
      }
      return value
    }
  }
}
