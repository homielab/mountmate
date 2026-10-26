//  Created by homielab.com

import AppIntents
import Foundation

/// A volume as a Shortcuts parameter. The identifier is the volume's name, so
/// a shortcut keeps working when the drive is unplugged and plugged in again
/// (device identifiers change); the action looks the name up when it runs.
struct VolumeEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Volume")
  }
  static var defaultQuery = VolumeQuery()

  let id: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(id)")
  }
}

struct VolumeQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [VolumeEntity] {
    identifiers.map(VolumeEntity.init(id:))
  }

  /// The volumes known right now; others can still be picked by variable.
  func suggestedEntities() async throws -> [VolumeEntity] {
    await Self.currentVolumeNames().map(VolumeEntity.init(id:))
  }

  @MainActor
  static func currentVolumeNames() async -> [String] {
    let manager = await IntentActions.refreshedDriveManager()
    let names = VolumeIntentPlanner.candidates(
      in: manager.physicalDisks ?? [], unverifiedDiskIDs: manager.unverifiedDiskIDs
    ).map(\.name)
    return Array(Set(names)).sorted()
  }
}
