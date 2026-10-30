//  Created by homielab.com

import Foundation

/// Decides what the volume Shortcuts actions (Mount, Unmount, Eject, Is
/// Volume Mounted, Get Mounted Volumes) do for a volume chosen by UUID or
/// name. Pure, so the matching, the answers and the error texts are testable.
enum VolumeIntentPlanner {
  /// What a saved shortcut remembers about its volume: the volume UUID when
  /// it has one (so two volumes with the same name stay apart) and the name
  /// (shown when the drive is unplugged, and matched when the UUID is gone).
  /// Shortcuts saved before UUIDs were stored hold only the name.
  struct Reference: Equatable, Sendable {
    let name: String
    let volumeUUID: String?

    private static let prefix = "volume-uuid:"

    init(name: String, volumeUUID: String?) {
      self.name = name
      self.volumeUUID = volumeUUID
    }

    init(volume: Volume) {
      self.init(name: volume.name, volumeUUID: volume.stableVolumeUUID)
    }

    /// Reads an identifier written by `identifier`; anything else (an
    /// older shortcut, a typed name) is a plain name.
    init(identifier: String) {
      let uuidLength = 36
      if identifier.hasPrefix(Self.prefix) {
        let rest = identifier.dropFirst(Self.prefix.count)
        let uuid = String(rest.prefix(uuidLength))
        let tail = rest.dropFirst(uuidLength)
        if UUID(uuidString: uuid) != nil, tail.first == ":" {
          self.init(name: String(tail.dropFirst()), volumeUUID: uuid)
          return
        }
      }
      self.init(name: identifier, volumeUUID: nil)
    }

    /// "volume-uuid:<UUID>:<name>", or just the name without a UUID.
    var identifier: String {
      guard let volumeUUID else { return name }
      return "\(Self.prefix)\(volumeUUID):\(name)"
    }
  }

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

  /// Finds the volume with this UUID; when none has it (another drive, or
  /// the volume was erased) or there is no UUID, falls back to the name.
  static func match(_ reference: Reference, in volumes: [Volume]) -> Match {
    if let uuid = reference.volumeUUID,
      let volume = volumes.first(where: {
        $0.stableVolumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame
      })
    {
      return .found(volume)
    }
    return match(name: reference.name, in: volumes)
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
    plan(Reference(name: name, volumeUUID: nil), in: volumes, mount: mount, localize: localize)
  }

  static func plan(
    _ reference: Reference, in volumes: [Volume], mount: Bool,
    localize: IntentMessages.Localize = IntentMessages.defaultLocalize
  ) -> Plan {
    let name = reference.name
    switch match(reference, in: volumes) {
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

  /// What "Get Mounted Volumes" lists: the mounted ordinary volumes of
  /// external disks (the same set as Mount Volume), in the order of the menu:
  /// external drives first, then disk images, each disk's volumes as listed.
  static func mountedVolumes(
    in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>
  ) -> [Volume] {
    let disks = BulkVolumeActions.actionableDisks(disks, unverifiedDiskIDs: unverifiedDiskIDs)
    let ordered = disks.filter { $0.type != .diskImage } + disks.filter { $0.type == .diskImage }
    return ordered.flatMap(\.allVolumes).filter { $0.category == .user && $0.isMounted }
  }

  enum MountedAnswer: Equatable {
    case answer(Bool)
    /// The intent fails with this message.
    case failure(String)
  }

  /// What "Is Volume Mounted" answers. A volume that is not connected is not
  /// mounted (so a shortcut can branch on a drive being plugged in); two
  /// volumes it cannot tell apart are an error rather than a guess.
  static func isMounted(
    _ reference: Reference, in volumes: [Volume],
    localize: IntentMessages.Localize = IntentMessages.defaultLocalize
  ) -> MountedAnswer {
    switch match(reference, in: volumes) {
    case .notFound: return .answer(false)
    case .ambiguous:
      return .failure(IntentMessages.volumeNameAmbiguous(name: reference.name, localize: localize))
    case .found(let volume): return .answer(volume.isMounted)
    }
  }

  /// Where `volume` is mounted according to `volumes` (the list read after
  /// the mount), found by its identifier, else its volume UUID; `nil` when it
  /// is not mounted there or reports no mount point.
  static func mountPoint(of volume: Volume, in volumes: [Volume]) -> String? {
    let current =
      volumes.first { $0.id == volume.id }
      ?? volume.stableVolumeUUID.flatMap { uuid in
        volumes.first { $0.stableVolumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame }
      }
    guard let current, current.isMounted,
      let path = current.mountPoint?.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    else { return nil }
    return path
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
    ejectPlan(
      Reference(name: name, volumeUUID: nil), in: disks, unverifiedDiskIDs: unverifiedDiskIDs,
      localize: localize)
  }

  static func ejectPlan(
    _ reference: Reference, in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String>,
    localize: IntentMessages.Localize = IntentMessages.defaultLocalize
  ) -> EjectPlan {
    let name = reference.name
    let external = disks.filter(\.isRemovable)
    let volumes = external.flatMap(\.allVolumes).filter { $0.category == .user }
    switch match(reference, in: volumes) {
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
