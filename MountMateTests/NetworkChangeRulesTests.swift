//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkChangeRulesTests: XCTestCase {
  private let wifi = InterfaceSnapshot(name: "en0", type: .wifi)
  private let wifi2 = InterfaceSnapshot(name: "en1", type: .wifi)
  private let ethernet = InterfaceSnapshot(name: "en5", type: .wiredEthernet)

  private func path(_ interfaces: [InterfaceSnapshot], satisfied: Bool = true)
    -> NetworkPathSnapshot
  {
    NetworkPathSnapshot(isSatisfied: satisfied, interfaces: interfaces)
  }

  func testFirstObservationAndRecoveryDoNotRemount() {
    XCTAssertFalse(
      NetworkChangeRules.shouldRemountShares(previous: nil, current: wifi, available: [wifi]))
    XCTAssertFalse(
      NetworkChangeRules.shouldRemountShares(previous: wifi, current: nil, available: []))
  }

  func testSameInterfaceDoesNotRemount() {
    XCTAssertFalse(
      NetworkChangeRules.shouldRemountShares(previous: wifi, current: wifi, available: [wifi]))
  }

  func testWifiToEthernetRemounts() {
    XCTAssertTrue(
      NetworkChangeRules.shouldRemountShares(
        previous: wifi, current: ethernet, available: [ethernet, wifi]))
  }

  func testLostInterfaceRemounts() {
    XCTAssertTrue(
      NetworkChangeRules.shouldRemountShares(previous: ethernet, current: wifi, available: [wifi]))
    XCTAssertTrue(
      NetworkChangeRules.shouldRemountShares(previous: wifi, current: wifi2, available: [wifi2]))
  }

  func testAnotherWifiWhileTheOldOneStaysDoesNotRemount() {
    XCTAssertFalse(
      NetworkChangeRules.shouldRemountShares(
        previous: wifi, current: wifi2, available: [wifi2, wifi]))
  }

  func testVPNComingAndGoingChangesNothing() {
    // Tunnels never reach the rules (`physicalInterfaces` drops them), so a
    // VPN going up or down yields the same snapshot as before.
    XCTAssertEqual(
      NetworkChangeRules.decision(previous: wifi, path: path([wifi])),
      .available(interface: wifi, remountShares: false, networkChanged: false))
  }

  func testNoPhysicalInterfaceButSatisfiedPath() {
    // Only a tunnel is up: nothing to compare, no remount; first sight counts
    // as a network change so the sweep resets backoff.
    XCTAssertEqual(
      NetworkChangeRules.decision(previous: nil, path: path([])),
      .available(interface: nil, remountShares: false, networkChanged: true))
    XCTAssertEqual(
      NetworkChangeRules.decision(previous: wifi, path: path([])),
      .available(interface: nil, remountShares: false, networkChanged: false))
  }

  func testUnavailablePath() {
    XCTAssertEqual(
      NetworkChangeRules.decision(previous: wifi, path: path([], satisfied: false)), .unavailable)
  }

  func testDecisionForSwitchAndRecovery() {
    XCTAssertEqual(
      NetworkChangeRules.decision(previous: wifi, path: path([ethernet, wifi])),
      .available(interface: ethernet, remountShares: true, networkChanged: true))
    XCTAssertEqual(
      NetworkChangeRules.decision(previous: nil, path: path([wifi])),
      .available(interface: wifi, remountShares: false, networkChanged: true))
  }
}
