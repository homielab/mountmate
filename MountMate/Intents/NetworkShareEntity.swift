//  Created by homielab.com

import AppIntents
import Foundation

/// A network share saved in MountMate, as a Shortcuts parameter.
struct NetworkShareEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Network Share")
  }
  static var defaultQuery = NetworkShareQuery()

  let id: UUID
  let name: String
  let server: String
  /// Whether the share was mounted when the entity was made.
  @Property(title: "Mounted")
  var isMounted: Bool
  /// Where it was mounted then, else `nil`.
  @Property(title: "Mount Point")
  var mountPoint: String?

  /// `mountPoint` is where the share is mounted now, `nil` when it is not.
  init(share: NetworkShare, mountPoint: String? = nil) {
    id = share.id
    name = share.name
    server = share.server
    let path = mountPoint?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.mountPoint = path?.isEmpty == false ? path : nil
    isMounted = self.mountPoint != nil
  }

  /// One entity per saved share, in the order of Settings, with the mount
  /// points of the mount table read last (`mountPoints`, by share id).
  static func entities(
    for shares: [NetworkShare], mountPoints: [UUID: String]
  ) -> [NetworkShareEntity] {
    shares.map { NetworkShareEntity(share: $0, mountPoint: mountPoints[$0.id]) }
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(server)")
  }
}

struct NetworkShareQuery: EntityQuery {
  func entities(for identifiers: [UUID]) async throws -> [NetworkShareEntity] {
    await Self.knownEntities().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [NetworkShareEntity] {
    await Self.knownEntities()
  }

  @MainActor
  static func savedShares() -> [NetworkShare] {
    PersistenceManager.shared.networkShares
  }

  /// The saved shares with the mount state read last, without a refresh
  /// (Shortcuts asks for entities often; Get Network Shares refreshes).
  @MainActor
  static func knownEntities() -> [NetworkShareEntity] {
    NetworkShareEntity.entities(
      for: savedShares(), mountPoints: NetworkMountManager.shared.mountPointsByShareID)
  }
}
