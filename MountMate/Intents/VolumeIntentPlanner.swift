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

  enum EjectPlan: Equatable {
    /// Eject this whole disk.
    case run(PhysicalDisk)
    /// The intent fails with this message.
    case failure(String)
  }

  /// What "Eject Volume" does for a volume name: the disk holding that volume
  /// is ejected. Only ordinary volumes of external disks match (internal disks
  /// are never found); a protected volume, a disk holding one, or a disk
  /// nothing could verify is refused.
  static func ejectPlan(
    name: String, in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>,
    localize: IntentMessages.Localize = IntentMessages.defaultLocalize
  ) -> EjectPlan {
    let external = disks.filter(\.isRemovable)
    let volumes = external.flatMap(\.allVolumes).filter { $0.category == .user }
    switch match(name: name, in: volumes) {
    case .notFound:
      return .failure(IntentMessages.volumeNotFound(name: name, localize: localize))
    case .ambiguous:
      return .failure(IntentMessages.volumeNameAmbiguous(name: name, localize: localize))
    case .found(let volume):
      if volume.isProtected {
        return .failure(IntentMessages.volumeProtected(name: volume.name, localize: localize))
      }
      guard let disk = external.first(where: { $0.allVolumes.contains { $0.id == volume.id } })
      else {
        return .failure(IntentMessages.volumeNotFound(name: name, localize: localize))
      }
      // Ejecting the disk unmounts all its volumes: another protected
      // volume on it keeps the whole disk (as Eject All does).
      if disk.allVolumes.contains(where: \.isProtected) {
        return .failure(
          IntentMessages.ejectDiskProtected(name: volume.name, localize: localize))
      }
      if disk.type != .diskImage && unverifiedDiskIDs.contains(disk.id) {
        return .failure(
          IntentMessages.ejectUnverified(name: disk.name ?? disk.id, localize: localize))
      }
      return .run(disk)
    }
  }
}
