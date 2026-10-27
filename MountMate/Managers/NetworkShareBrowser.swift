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
  /// The latest full result set of each browser, keyed by Bonjour type. Each
  /// NWBrowser reports its complete current list, so a server that leaves
  /// Bonjour drops out of its entry and therefore out of `services`.
  private var resultsByType: [String: [DiscoveredShareService]] = [:]
  /// Bumped by every start and stop; callbacks queued for an older session
  /// are ignored so a closed picker never refills its list.
  private var session = 0
  private var isActive = false
  private var graceWork: DispatchWorkItem?
  private let queue = DispatchQueue(label: "com.homielab.mountmate.browse")
  private let foundGracePeriod: TimeInterval
  private let browsesNetwork: Bool

  /// `browsesNetwork: false` starts a session without NWBrowsers, so tests
  /// can feed results through `handle(results:type:)`.
  init(foundGracePeriod: TimeInterval = 6, browsesNetwork: Bool = true) {
    self.foundGracePeriod = foundGracePeriod
    self.browsesNetwork = browsesNetwork
  }

  /// Starts browsing (once). Call on the main thread; updates publish on main.
  func start() {
    guard !isActive else { return }
    isActive = true
    session += 1
    let current = session
    resultsByType.removeAll()
    services.removeAll()
    failed = false
    isBrowsing = true
    if browsesNetwork {
      for type in NetworkServiceResolver.browsedTypes {
        browsers.append(makeBrowser(type: type, session: current))
      }
    }
    // The "none found" state: no service within the grace period ends the
    // spinner (browsing keeps running, so late servers still appear).
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.isActive, self.session == current, self.services.isEmpty else {
        return
      }
      self.isBrowsing = false
    }
    graceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + foundGracePeriod, execute: work)
  }

  /// Stops browsing and forgets the results (the picker closed).
  func stop() {
    isActive = false
    session += 1
    graceWork?.cancel()
    graceWork = nil
    for browser in browsers {
      browser.cancel()
    }
    browsers.removeAll()
    resultsByType.removeAll()
    services.removeAll()
    isBrowsing = false
    failed = false
  }

  /// Replaces one browser's results with its latest full list and rebuilds
  /// the published services from every browser's results (deduplicated and
  /// sorted by the resolver). Ignored when not browsing. Call on main.
  func handle(results: [DiscoveredShareService], type: String) {
    guard isActive else { return }
    resultsByType[type] = results
    let merged = NetworkServiceResolver.resolve(
      resultsByType.sorted { $0.key < $1.key }.flatMap(\.value))
    services = merged
    if !merged.isEmpty { isBrowsing = false }
  }

  private func makeBrowser(type: String, session current: Int) -> NWBrowser {
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
      DispatchQueue.main.async {
        guard let self, self.session == current else { return }
        self.handle(results: discovered, type: type)
      }
    }
    browser.stateUpdateHandler = { [weak self] state in
      if case .failed = state {
        DispatchQueue.main.async {
          guard let self, self.isActive, self.session == current else { return }
          self.failed = true
          self.isBrowsing = false
        }
      }
    }
    browser.start(queue: queue)
    return browser
  }
}
