//  Created by homielab.com

import Foundation

/// A share service discovered on the local network, ready to fill the
/// Server Address and Protocol fields of the share sheet.
struct BrowsedShareService: Equatable, Identifiable, Sendable {
  /// The server's host name ("Johns-MacBook-Pro.local"): the one the
  /// service resolved to, else one derived from the service name.
  let host: String
  /// The port the service announced when it is not the protocol's default.
  var port: Int? = nil
  let shareProtocol: ShareProtocol
  /// The name the server announced (the picker's label).
  let displayName: String

  /// What goes into the Server Address field: the host, with the port when
  /// the service runs on a non-default one ("nas.local:1445").
  var serverAddress: String {
    port.map { "\(host):\($0)" } ?? host
  }

  var id: String { "\(serverAddress)-\(shareProtocol.rawValue)".lowercased() }
}

/// A service the Bonjour browser found, before resolving.
struct DiscoveredShareService: Hashable, Sendable {
  /// The service name NWBrowser reports ("My NAS").
  let name: String
  /// The Bonjour service type ("_smb._tcp", "_nfs._tcp").
  let type: String
  /// The Bonjour domain the service was found in ("local.").
  let domain: String

  init(name: String, type: String, domain: String = "local.") {
    self.name = name
    self.type = type
    self.domain = domain.isEmpty ? "local." : domain
  }
}

/// What resolving a Bonjour service returned: the host name its records
/// point to ("Johns-MacBook-Pro.local.") and its port.
struct ResolvedServiceAddress: Equatable, Sendable {
  let hostTarget: String
  let port: Int
}

/// Pure decisions for the network browser: which Bonjour types to browse,
/// how a discovered service maps to a host and protocol, and which
/// duplicates collapse. No Network framework types, so every branch is
/// unit-tested with fake service lists.
enum NetworkServiceResolver {
  /// The Bonjour service types the browser looks for.
  static let browsedTypes = ["_smb._tcp", "_nfs._tcp"]

  /// Converts discovered services into pickable entries. The host is the
  /// host name the service resolved to (`resolved`) or, until then or when
  /// resolving failed, one derived from the service name
  /// (`fallbackHost(forServiceName:)`): a service name such as "My NAS" is
  /// a label, not an address. The protocol comes from the service type,
  /// duplicates (the same service announced through several interfaces)
  /// collapse, and the rest sorts by display name so the picker is stable.
  static func resolve(
    _ services: [DiscoveredShareService],
    resolved: [DiscoveredShareService: ResolvedServiceAddress] = [:]
  ) -> [BrowsedShareService] {
    let known = services.compactMap { service -> BrowsedShareService? in
      guard let shareProtocol = shareProtocol(for: service.type) else { return nil }
      if let address = resolved[service],
        let host = host(fromHostTarget: address.hostTarget)
      {
        return BrowsedShareService(
          host: host, port: nonDefaultPort(address.port, for: shareProtocol),
          shareProtocol: shareProtocol, displayName: displayName(service.name))
      }
      let host = fallbackHost(forServiceName: service.name)
      guard !host.isEmpty else { return nil }
      return BrowsedShareService(
        host: host, shareProtocol: shareProtocol, displayName: displayName(service.name))
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

  /// "Johns-MacBook-Pro.local." → "Johns-MacBook-Pro.local": the resolved
  /// host name without the root dot. Nil when empty or not a usable host
  /// name (whitespace inside), so the caller falls back to the service name.
  static func host(fromHostTarget target: String) -> String? {
    var host = target.trimmingCharacters(in: .whitespacesAndNewlines)
    while host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
    return host
  }

  /// The host name macOS gives a computer named like the service, for a
  /// service that could not be resolved: "My NAS" → "my-nas.local",
  /// "John's MacBook Pro" → "johns-macbook-pro.local". Apostrophes are
  /// dropped, accents folded, any other run of characters that is not a
  /// letter or digit becomes one "-". Empty when nothing usable is left.
  static func fallbackHost(forServiceName name: String) -> String {
    var label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while label.hasSuffix(".") { label.removeLast() }
    if label.lowercased().hasSuffix(".local") {
      label = String(label.dropLast(".local".count))
    }
    label = label.folding(
      options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
    label = label.replacingOccurrences(of: "đ", with: "d")
    let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`"]
    var host = ""
    var pendingHyphen = false
    for character in label where !apostrophes.contains(character) {
      if character.isASCII, character.isLetter || character.isNumber {
        if pendingHyphen, !host.isEmpty { host.append("-") }
        pendingHyphen = false
        host.append(character)
      } else {
        pendingHyphen = true
      }
    }
    return host.isEmpty ? "" : host + ".local"
  }

  /// The announced name as the picker shows it (surrounding whitespace off).
  private static func displayName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The port worth writing into the address: nil for the protocol's default
  /// port (445 SMB, 2049 NFS) and for a missing one (0).
  static func nonDefaultPort(_ port: Int, for shareProtocol: ShareProtocol) -> Int? {
    guard port > 0, port <= 65_535 else { return nil }
    let defaultPort: Int
    switch shareProtocol {
    case .smb: defaultPort = 445
    case .nfs: defaultPort = 2049
    case .afp: defaultPort = 548
    }
    return port == defaultPort ? nil : port
  }
}
