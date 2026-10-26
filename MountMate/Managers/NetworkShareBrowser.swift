//  Created by homielab.com

import Foundation
import Network

/// Browses the local network for SMB and NFS share services with NWBrowser
/// (the types in `NetworkServiceResolver.browsedTypes`, which Info.plist's
/// `NSBonjourServices` lists). Publishes the resolved services and the state
/// the picker shows: browsing, done, or failed — local-network permission
/// denied surfaces as a failure, and typing the address by hand always works.
final class NetworkShareBrowser: ObservableObject {
  @Published private(set) var services: [BrowsedShareService] = []
  /// True while browsing and nothing was found yet; false once services
  /// arrived or the grace period passed (the "none found" state).
  @Published private(set) var isBrowsing = false
  @Published private(set) var failed = false

  private var browsers: [NWBrowser] = []
  private let queue = DispatchQueue(label: "com.homielab.mountmate.browse")
  private let foundGracePeriod: TimeInterval

  init(foundGracePeriod: TimeInterval = 6) {
    self.foundGracePeriod = foundGracePeriod
  }

  /// Starts browsing (once). Call on the main thread; updates publish on main.
  func start() {
    guard browsers.isEmpty else { return }
    failed = false
    isBrowsing = true
    for type in NetworkServiceResolver.browsedTypes {
      let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        let discovered = results.compactMap { result -> DiscoveredShareService? in
          // A Bonjour result's endpoint is the .service case with the name
          // and type the resolver needs.
          if case .service(let name, let serviceType, _, _) = result.endpoint {
            return DiscoveredShareService(name: name, type: serviceType)
          }
          return nil
        }
        let resolved = NetworkServiceResolver.resolve(discovered)
        DispatchQueue.main.async {
          guard let self else { return }
          // Both browsers report into one list; the resolver dedupes.
          self.merge(resolved)
        }
      }
      browser.stateUpdateHandler = { [weak self] state in
        if case .failed = state {
          DispatchQueue.main.async {
            guard let self, !self.browsers.isEmpty else { return }
            self.failed = true
            self.isBrowsing = false
          }
        }
      }
      browser.start(queue: queue)
      browsers.append(browser)
    }
    // The "none found" state: no service within the grace period ends the
    // spinner (browsing keeps running, so late servers still appear).
    DispatchQueue.main.asyncAfter(deadline: .now() + foundGracePeriod) { [weak self] in
      guard let self, self.services.isEmpty else { return }
      self.isBrowsing = false
    }
  }

  /// Stops browsing and forgets the results (the picker closed).
  func stop() {
    for browser in browsers {
      browser.cancel()
    }
    browsers.removeAll()
    services.removeAll()
    isBrowsing = false
    failed = false
  }

  /// Merges one browser's batch into the published list (deduplicated by the
  /// resolver, order kept stable).
  private func merge(_ batch: [BrowsedShareService]) {
    let merged = NetworkServiceResolver.resolve(
      (services + batch).map {
        DiscoveredShareService(name: $0.displayName, type: "_\($0.shareProtocol.rawValue)._tcp")
      })
    services = merged
    if !merged.isEmpty { isBrowsing = false }
  }
}
