//  Created by homielab.com

import AppIntents
import Foundation

/// A volume as a Shortcuts parameter. The identifier holds the volume UUID and
/// name (`VolumeIntentPlanner.Reference`), not a device identifier, so a
/// shortcut keeps working when the drive is unplugged and plugged in again,
/// and two volumes with the same name ("Untitled") stay apart. Shortcuts saved
/// with only a name still work: the action then looks the name up.
struct VolumeEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Volume")
  }
  static var defaultQuery = VolumeQuery()

  let id: String
  /// Size and BSD name (plus mount point when mounted) of the volume while it
  /// is connected, so the picker can tell same-named volumes apart.
  let subtitle: String?
  /// Whether the volume was mounted when the entity was made; false when it
  /// is not connected.
  @Property(title: "Mounted")
  var isMounted: Bool
  /// Where it was mounted then ("/Volumes/Backup"), else `nil`.
  @Property(title: "Mount Point")
  var mountPoint: String?

  var reference: VolumeIntentPlanner.Reference {
    VolumeIntentPlanner.Reference(identifier: id)
  }

  var name: String { reference.name }

  init(id: String, subtitle: String? = nil, isMounted: Bool = false, mountPoint: String? = nil) {
    self.id = id
    self.subtitle = subtitle
    self.isMounted = isMounted
    self.mountPoint = mountPoint
  }

  init(volume: Volume) {
    self.init(id: VolumeIntentPlanner.Reference(volume: volume).identifier, current: volume)
  }

  /// `identifier` with the subtitle and mount state of `volume`, the volume
  /// it stands for as connected now.
  init(id identifier: String, current volume: Volume) {
    self.init(
      id: identifier, subtitle: Self.subtitle(for: volume), isMounted: volume.isMounted,
      mountPoint: VolumeIntentPlanner.mountPoint(of: volume, in: [volume]))
  }

  /// "16 GB · disk4s1 · /Volumes/Untitled 1"; parts that are unknown are left out.
  static func subtitle(for volume: Volume) -> String? {
    let parts = [volume.totalSize, volume.deviceIdentifier, volume.mountPoint]
      .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  var displayRepresentation: DisplayRepresentation {
    if let subtitle {
      return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }
    return DisplayRepresentation(title: "\(name)")
  }
}

struct VolumeQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [VolumeEntity] {
    let current = await Self.knownVolumes()
    return Self.entities(for: identifiers, current: current)
  }

  /// Every volume known right now, same-named ones included; others can
  /// still be picked by variable.
  func suggestedEntities() async throws -> [VolumeEntity] {
    Self.suggestions(from: await Self.currentVolumes())
  }

  /// One entity per identifier; a volume that is connected gets its
  /// subtitle and mount state, one that is not keeps its name only.
  static func entities(for identifiers: [String], current: [Volume]) -> [VolumeEntity] {
    identifiers.map { identifier in
      guard let uuid = VolumeIntentPlanner.Reference(identifier: identifier).volumeUUID,
        let volume = current.first(where: {
          $0.stableVolumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame
        })
      else { return VolumeEntity(id: identifier) }
      return VolumeEntity(id: identifier, current: volume)
    }
  }

  /// One entry per volume, sorted by name then subtitle. Volumes without a
  /// UUID are identified by name, so same-named ones of those collapse into
  /// one entry (picking it fails as ambiguous, as it always did).
  static func suggestions(from volumes: [Volume]) -> [VolumeEntity] {
    var seen = Set<String>()
    return volumes.map(VolumeEntity.init(volume:))
      .filter { seen.insert($0.id).inserted }
      .sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        if order != .orderedSame { return order == .orderedAscending }
        return ($0.subtitle ?? "") < ($1.subtitle ?? "")
      }
  }

  @MainActor
  static func currentVolumes() async -> [Volume] {
    _ = await IntentActions.refreshedDriveManager()
    return knownVolumes()
  }

  /// The volumes read last, without a refresh (Shortcuts asks for entities
  /// often; the action itself refreshes before it runs).
  @MainActor
  static func knownVolumes() -> [Volume] {
    let manager = DriveManager.shared
    return VolumeIntentPlanner.candidates(
      in: manager.physicalDisks ?? [], unverifiedDiskIDs: manager.unverifiedDiskIDs)
  }
}
