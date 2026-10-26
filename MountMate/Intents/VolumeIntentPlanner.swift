//  Created by homielab.com

import Foundation

/// Decides what the "Mount Volume" / "Unmount Volume" Shortcuts actions do for
/// a volume name. Pure, so the matching and the error texts are testable.
enum VolumeIntentPlanner {
  enum Match: Equatable {
    case found(Volume)
    case notFound
    case ambiguous
  }

  enum Plan: Equatable {
    /// Mount or unmount this volume.
    case run(Volume)
    /// Already in the requested state: nothing to do, the intent succeeds.
    case alreadyDone(Volume)
    /// The intent fails with this message.
    case failure(String)
  }

  /// The volumes a Shortcuts action may address: ordinary volumes of external
  /// disks, not EFI or other system partitions and not internal disks (the
  /// same set as Mount All / Unmount All).
  static func candidates(in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>) -> [Volume] {
    BulkVolumeActions.actionableDisks(disks, unverifiedDiskIDs: unverifiedDiskIDs)
      .flatMap(\.allVolumes).filter { $0.category == .user }
  }

  /// Finds a volume by name, ignoring case and surrounding spaces. When
  /// several volumes differ only by case, an exact-case match wins; two
  /// volumes with the very same name are ambiguous.
  static func match(name: String, in volumes: [Volume]) -> Match {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return .notFound }
    let loose = volumes.filter {
      $0.name.compare(wanted, options: [.caseInsensitive]) == .orderedSame
    }
    switch loose.count {
    case 0: return .notFound
    case 1: return .found(loose[0])
    default:
      let exact = loose.filter { $0.name == wanted }
      return exact.count == 1 ? .found(exact[0]) : .ambiguous
    }
  }

  static func plan(
    name: String, in volumes: [Volume], mount: Bool,
    localize: IntentMessages.Localize = IntentMessages.defaultLocalize
  ) -> Plan {
    switch match(name: name, in: volumes) {
    case .notFound:
      return .failure(IntentMessages.volumeNotFound(name: name, localize: localize))
    case .ambiguous:
      return .failure(IntentMessages.volumeNameAmbiguous(name: name, localize: localize))
    case .found(let volume):
      if mount { return volume.isMounted ? .alreadyDone(volume) : .run(volume) }
      if volume.isProtected {
        return .failure(IntentMessages.volumeProtected(name: volume.name, localize: localize))
      }
      return volume.isMounted ? .run(volume) : .alreadyDone(volume)
    }
  }
}
