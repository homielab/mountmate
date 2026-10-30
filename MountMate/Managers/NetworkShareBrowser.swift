//  Created by homielab.com

import Foundation
import Network

/// Browses the local network for SMB and NFS share services with NWBrowser
/// (the types in `NetworkServiceResolver.browsedTypes`, which Info.plist's
/// `NSBonjourServices` lists) and resolves each service found to the host
/// name it announces (`BonjourServiceLookup`), since a service name such as
/// "My NAS" is not an address. Publishes the services and the state
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
  /// Host names and ports of the services resolved so far.
  private var resolvedAddresses: [DiscoveredShareService: ResolvedServiceAddress] = [:]
  /// Lookups started this session (running or finished), one per service.
  private var lookups: [DiscoveredShareService: BonjourServiceLookup] = [:]
  /// Bumped by every start and stop; callbacks queued for an older session
  /// are ignored so a closed picker never refills its list.
  private var session = 0
  private var isActive = false
  private var graceWork: DispatchWorkItem?
  private let queue = DispatchQueue(label: "com.homielab.mountmate.browse")
  private let foundGracePeriod: TimeInterval
  private let browsesNetwork: Bool
  private let resolveTimeout: TimeInterval = 5

  /// `browsesNetwork: false` starts a session without NWBrowsers or lookups,
  /// so tests can feed results through `handle(results:type:)` and
  /// `handle(resolved:for:)`.
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
    resolvedAddresses.removeAll()
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
    for lookup in lookups.values {
      lookup.cancel()
    }
    lookups.removeAll()
    resultsByType.removeAll()
    resolvedAddresses.removeAll()
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
    if browsesNetwork {
      for service in results where lookups[service] == nil {
        startLookup(for: service, session: session)
      }
    }
    publish()
  }

  /// Records the host name and port a service resolved to and republishes,
  /// so the picker shows (and fills in) the real host. Ignored when not
  /// browsing. Call on main.
  func handle(resolved address: ResolvedServiceAddress, for service: DiscoveredShareService) {
    guard isActive else { return }
    resolvedAddresses[service] = address
    publish()
  }

  private func publish() {
    let merged = NetworkServiceResolver.resolve(
      resultsByType.sorted { $0.key < $1.key }.flatMap(\.value),
      resolved: resolvedAddresses)
    services = merged
    if !merged.isEmpty { isBrowsing = false }
  }

  /// Resolves a service once per session; a failed or timed-out lookup
  /// leaves the host derived from the service name.
  private func startLookup(for service: DiscoveredShareService, session current: Int) {
    let lookup = BonjourServiceLookup(queue: queue)
    lookups[service] = lookup
    lookup.start(service, timeout: resolveTimeout) { [weak self] address in
      guard let address else { return }
      DispatchQueue.main.async {
        guard let self, self.session == current else { return }
        self.handle(resolved: address, for: service)
      }
    }
  }

  private func makeBrowser(type: String, session current: Int) -> NWBrowser {
    let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let discovered = results.compactMap { result -> DiscoveredShareService? in
        // A Bonjour result's endpoint is the .service case with the name
        // and type the resolver needs.
        if case .service(let name, let serviceType, let domain, _) = result.endpoint {
          return DiscoveredShareService(name: name, type: serviceType, domain: domain)
        }
        return nil
      }
      DispatchQueue.main.async {
        guard let self, self.session == current else { return }
        self.handle(results: discovered, type: type)
      }
    }
    browser.stateUpdateHandler = { [weak self] state in
      if Self.isFailure(state) {
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

  /// Whether a browser state means no servers can be listed. Denied local
  /// network access arrives as `.waiting` with a DNS policy error, not
  /// `.failed`, so it is a failure too; other waiting states may recover.
  static func isFailure(_ state: NWBrowser.State) -> Bool {
    switch state {
    case .failed:
      return true
    case .waiting(let error):
      return isPermissionDenied(error)
    default:
      return false
    }
  }

  static func isPermissionDenied(_ error: NWError) -> Bool {
    guard case .dns(let code) = error else { return false }
    return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
      || code == DNSServiceErrorType(kDNSServiceErr_NoAuth)
  }
}
