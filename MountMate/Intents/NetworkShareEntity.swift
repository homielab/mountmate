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

  init(share: NetworkShare) {
    id = share.id
    name = share.name
    server = share.server
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(server)")
  }
}

struct NetworkShareQuery: EntityQuery {
  func entities(for identifiers: [UUID]) async throws -> [NetworkShareEntity] {
    await Self.savedShares().filter { identifiers.contains($0.id) }.map(NetworkShareEntity.init)
  }

  func suggestedEntities() async throws -> [NetworkShareEntity] {
    await Self.savedShares().map(NetworkShareEntity.init)
  }

  @MainActor
  static func savedShares() -> [NetworkShare] {
    PersistenceManager.shared.networkShares
  }
}
