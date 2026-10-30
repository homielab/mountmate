import XCTest

@testable import MountMate

final class MenuBarIconStateTests: XCTestCase {
  private func state(
    unmountingAll: Bool = false, busyVolume: Bool = false, busyEject: Bool = false,
    error: Bool = false, reconnecting: Bool = false
  ) -> MenuBarIconState {
    MenuBarIconState(
      isUnmountingAll: unmountingAll, busyVolume: busyVolume, busyEject: busyEject, error: error,
      reconnecting: reconnecting)
  }

  func testIdleWhenNothingHappens() {
    XCTAssertEqual(state(), .idle)
    XCTAssertNil(MenuBarIconState.idle.accessibilityKey)
  }

  func testEachBusyFlagShowsBusy() {
    XCTAssertEqual(state(unmountingAll: true), .busy)
    XCTAssertEqual(state(busyVolume: true), .busy)
    XCTAssertEqual(state(busyEject: true), .busy)
  }

  func testReconnectingAloneShowsReconnecting() {
    XCTAssertEqual(state(reconnecting: true), .reconnecting)
  }

  func testPriorityIsErrorThenBusyThenReconnecting() {
    XCTAssertEqual(state(busyVolume: true, reconnecting: true), .busy)
    XCTAssertEqual(state(busyVolume: true, error: true, reconnecting: true), .error)
  }

  func testSymbolsAreDistinctAndKeysExist() {
    let all: [MenuBarIconState] = [.idle, .busy, .reconnecting, .error]
    XCTAssertEqual(Set(all.map(\.symbolName)).count, 4)
    XCTAssertFalse(MenuBarIconState.busy.symbolName.contains("timemachine"))
    for symbol in all.map(\.symbolName) {
      XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
    }
    for key in all.compactMap(\.accessibilityKey) {
      XCTAssertNotEqual(NSLocalizedString(key, comment: ""), key)
    }
  }
}
