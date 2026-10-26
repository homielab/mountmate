//  Created by homielab.com

import Foundation
import Network

/// A physical (non-tunnel) network interface.
struct InterfaceSnapshot: Equatable {
  let name: String
  let type: NWInterface.InterfaceType
}

/// What a network path update says, reduced to what keep-alive needs.
struct NetworkPathSnapshot: Equatable {
  /// The path can reach the network (`NWPath.Status.satisfied`).
  let isSatisfied: Bool
  /// Physical interfaces in path order (the first is the primary one).
  let interfaces: [InterfaceSnapshot]
}

/// What keep-alive should do after a path update.
enum NetworkChangeDecision: Equatable {
  /// The network is gone; wait for it to come back.
  case unavailable
  /// The network is up. `interface` is the primary physical interface now.
  /// `remountShares`: the interface the shares were reached through changed
  /// kind or went away. `networkChanged`: back online or on another
  /// interface, so earlier failures say nothing about reachability now.
  case available(interface: InterfaceSnapshot?, remountShares: Bool, networkChanged: Bool)
}

/// The decisions behind network-change handling, free of `NWPath` and of any
/// manager state so they can be unit tested.
enum NetworkChangeRules {
  /// The path's physical interfaces in path order, ignoring VPN tunnels
  /// (utun, ipsec — reported as `.other`) and loopback, whose coming and
  /// going says nothing about how the shares' server is reached.
  static func physicalInterfaces(of path: NWPath) -> [InterfaceSnapshot] {
    path.availableInterfaces
      .filter { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
      .map { InterfaceSnapshot(name: $0.name, type: $0.type) }
  }

  /// Whether mounted shares should be remounted after a path update: only
  /// when the interface they were reached through is gone, or the primary
  /// physical interface changed kind (e.g. Wi-Fi → Ethernet). Changes that
  /// only add, remove or reorder tunnel/loopback interfaces never qualify.
  static func shouldRemountShares(
    previous: InterfaceSnapshot?, current: InterfaceSnapshot?, available: [InterfaceSnapshot]
  ) -> Bool {
    // First observation, or recovering from "no network": the reconnect
    // sweep handles that.
    guard let previous, let current else { return false }
    if !available.contains(where: { $0.name == previous.name }) { return true }
    return current.type != previous.type
  }

  /// `previous` is the primary interface of the last satisfied update (nil
  /// at start and after the network was lost).
  static func decision(
    previous: InterfaceSnapshot?, path: NetworkPathSnapshot
  ) -> NetworkChangeDecision {
    guard path.isSatisfied else { return .unavailable }
    // NWPath does not document interface ordering, but in practice the
    // first entry is the primary interface the path is routed through.
    let current = path.interfaces.first
    let remount = shouldRemountShares(
      previous: previous, current: current, available: path.interfaces)
    return .available(
      interface: current, remountShares: remount, networkChanged: previous == nil || remount)
  }
}

/// Source of network path updates. Delivers on the main thread.
protocol NetworkChangeMonitoring: AnyObject {
  var onChange: ((NetworkPathSnapshot) -> Void)? { get set }
  func start()
  func stop()
}

/// `NWPathMonitor` behind `NetworkChangeMonitoring`.
final class NetworkChangeMonitor: NetworkChangeMonitoring {
  var onChange: ((NetworkPathSnapshot) -> Void)?

  private var monitor: NWPathMonitor?
  private let queue = DispatchQueue(label: "com.homielab.mountmate.pathmonitor")

  func start() {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      let snapshot = NetworkPathSnapshot(
        isSatisfied: path.status == .satisfied,
        interfaces: NetworkChangeRules.physicalInterfaces(of: path))
      // NWPathMonitor calls back on its own queue; the settings, share list
      // and interface tracking of the receiver are main-thread state.
      DispatchQueue.main.async { self?.onChange?(snapshot) }
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor?.cancel()
    monitor = nil
  }

  deinit { stop() }
}
