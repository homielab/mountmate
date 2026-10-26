//  Created by homielab.com

import Foundation

/// A share service discovered on the local network, ready to fill the
/// Server Address and Protocol fields of the share sheet.
struct BrowsedShareService: Equatable, Identifiable, Sendable {
  let host: String
  let shareProtocol: ShareProtocol
  /// The name the server announced (the picker's label).
  let displayName: String

  var id: String { "\(host)-\(shareProtocol.rawValue)".lowercased() }
}

/// A service the Bonjour browser found, before resolving.
struct DiscoveredShareService: Equatable, Sendable {
  /// The service name NWBrowser reports ("My NAS").
  let name: String
  /// The Bonjour service type ("_smb._tcp", "_nfs._tcp").
  let type: String
}

/// Pure decisions for the network browser: which Bonjour types to browse,
/// how a discovered service maps to a host and protocol, and which
/// duplicates collapse. No Network framework types, so every branch is
/// unit-tested with fake service lists.
enum NetworkServiceResolver {
  /// The Bonjour service types the browser looks for.
  static let browsedTypes = ["_smb._tcp", "_nfs._tcp"]

  /// Converts discovered services into pickable entries: the host is the
  /// announced service name with any domain suffix stripped, the protocol
  /// comes from the service type, duplicates (the same service announced
  /// through several interfaces) collapse, and the rest sorts by display
  /// name so the picker is stable.
  static func resolve(_ services: [DiscoveredShareService]) -> [BrowsedShareService] {
    let known = services.compactMap { service -> BrowsedShareService? in
      guard let shareProtocol = shareProtocol(for: service.type) else { return nil }
      let host = hostFromServiceName(service.name)
      guard !host.isEmpty else { return nil }
      return BrowsedShareService(
        host: host, shareProtocol: shareProtocol, displayName: service.name)
    }
    let sorted = known.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
        == .orderedAscending
    }
    var seen = Set<String>()
    var result: [BrowsedShareService] = []
    for service in sorted {
      if seen.insert(service.id).inserted {
        result.append(service)
      }
    }
    return result
  }

  /// "_smb._tcp" → .smb, "_nfs._tcp." → .nfs; anything else (AFP, printer
  /// types, …) is not a share MountMate can mount from the browse list.
  static func shareProtocol(for type: String) -> ShareProtocol? {
    let lowered = type.lowercased()
    if lowered.contains("_smb") { return .smb }
    if lowered.contains("_nfs") { return .nfs }
    return nil
  }

  /// "MyNAS" → "MyNAS", "MyNAS.local." → "MyNAS": the announced name with
  /// surrounding whitespace and the mDNS domain suffix stripped.
  static func hostFromServiceName(_ name: String) -> String {
    var host = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while host.hasSuffix(".") { host.removeLast() }
    if host.lowercased().hasSuffix(".local") {
      host = String(host.dropLast(".local".count))
    }
    return host.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
