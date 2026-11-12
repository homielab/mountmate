//  Created by homielab.com

import Foundation

/// The process diskutil named as the reason a disk could not be ejected,
/// described in words users know ("Spotlight indexing" instead of `mds`).
struct BlockingProcess: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// A macOS service, shown with an SF Symbol.
    case system(symbol: String)
    /// An app; `bundlePath` is its `.app` bundle when known (its icon).
    case app(bundlePath: String?)
    /// A process MountMate does not know: shown by its own name.
    case unknown
  }

  /// The executable name diskutil printed, e.g. `mds_stores`.
  let rawName: String
  /// What the alert shows, e.g. "Spotlight indexing".
  let displayName: String
  let kind: Kind
  /// The process ID diskutil printed, if any.
  var pid: Int32?
}

/// Maps process names to friendly names and icons. Pure, so the table is
/// tested without running any process.
enum BlockingProcessNames {
  private enum Service {
    case spotlight, quickLook, timeMachine, iCloudDrive, terminalShell, fileTracking
    case malwareScan, diskCheck

    var symbol: String {
      switch self {
      case .spotlight: return "magnifyingglass"
      case .quickLook: return "eye"
      case .timeMachine: return "clock.arrow.circlepath"
      case .iCloudDrive: return "icloud"
      case .terminalShell: return "terminal"
      case .fileTracking: return "doc.text.magnifyingglass"
      case .malwareScan: return "checkmark.shield"
      case .diskCheck: return "stethoscope"
      }
    }

    var name: String {
      switch self {
      case .spotlight:
        return NSLocalizedString(
          "Spotlight indexing", comment: "Blocking process: Spotlight is indexing the disk")
      // Product names, the same in every language.
      case .quickLook: return "Quick Look"
      case .timeMachine: return "Time Machine"
      case .iCloudDrive: return "iCloud Drive"
      case .terminalShell:
        return NSLocalizedString(
          "Terminal shell", comment: "Blocking process: a shell (zsh, bash) open on the disk")
      case .fileTracking:
        return NSLocalizedString(
          "macOS file tracking", comment: "Blocking process: fseventsd, records file changes")
      case .malwareScan:
        return NSLocalizedString(
          "Malware scan", comment: "Blocking process: XProtect scanning the disk")
      case .diskCheck:
        return NSLocalizedString("Disk check", comment: "Blocking process: fsck checking the disk")
      }
    }
  }

  /// Lower-cased executable names of macOS services.
  private static let services: [String: Service] = {
    let table: [(Service, [String])] = [
      (
        .spotlight,
        [
          "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "mdbulkimport", "mdimport",
          "corespotlightd", "spotlight",
        ]
      ),
      (
        .quickLook,
        [
          "quicklookuiservice", "quicklookd", "quicklooksatellite", "qlmanage",
          "com.apple.quicklook.thumbnailsagent",
        ]
      ),
      (.timeMachine, ["backupd", "backupd-helper"]),
      (.iCloudDrive, ["bird", "cloudd", "fileproviderd"]),
      (
        .terminalShell,
        ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "-zsh", "-bash"]
      ),
      (.fileTracking, ["fseventsd"]),
      (.malwareScan, ["xprotect", "xprotectservice", "xprotectpluginservice", "mrt"]),
      (.diskCheck, ["fsck"]),
    ]
    var map: [String: Service] = [:]
    for (service, names) in table {
      for name in names { map[name] = service }
    }
    return map
  }()

  static let finderBundlePath = "/System/Library/CoreServices/Finder.app"

  /// Describes the process at `path` (a full executable path, or just a
  /// name when that is all diskutil printed).
  static func describe(path: String, pid: Int32? = nil) -> BlockingProcess {
    let rawName = (path as NSString).lastPathComponent
    let key = rawName.lowercased()
    if let service = services[key] ?? (key.hasPrefix("fsck_") ? .diskCheck : nil) {
      return BlockingProcess(
        rawName: rawName, displayName: service.name, kind: .system(symbol: service.symbol), pid: pid
      )
    }
    if let bundle = outermostAppBundle(in: path) {
      let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
      return BlockingProcess(
        rawName: rawName, displayName: name, kind: .app(bundlePath: bundle), pid: pid)
    }
    if key == "finder" {
      return BlockingProcess(
        rawName: rawName, displayName: "Finder", kind: .app(bundlePath: finderBundlePath), pid: pid)
    }
    return BlockingProcess(rawName: rawName, displayName: rawName, kind: .unknown, pid: pid)
  }

  /// The first `.app` bundle in `path`, so a helper inside an app
  /// (`Chrome.app/…/Chrome Helper.app/…`) is named after the app users know.
  static func outermostAppBundle(in path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }
    var components: [String] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
      components.append(String(part))
      if part.lowercased().hasSuffix(".app") {
        return "/" + components.joined(separator: "/")
      }
    }
    return nil
  }
}
