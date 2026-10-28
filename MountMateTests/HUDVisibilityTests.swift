import XCTest

@testable import MountMate

final class HUDVisibilityTests: XCTestCase {
  func testGenerationIncreasesWithEachShow() {
    var visibility = HUDVisibility()
    XCTAssertEqual(visibility.show(), 1)
    XCTAssertEqual(visibility.show(), 2)
    XCTAssertEqual(visibility.show(), 3)
    XCTAssertEqual(visibility.generation, 3)
  }

  func testCurrentShowMayHide() {
    var visibility = HUDVisibility()
    let shown = visibility.show()
    XCTAssertTrue(visibility.isCurrent(shown))
  }

  func testNewShowCancelsPendingHide() {
    // The first message's hide is still waiting when the second one shows.
    var visibility = HUDVisibility()
    let first = visibility.show()
    let second = visibility.show()
    XCTAssertFalse(visibility.isCurrent(first))
    XCTAssertTrue(visibility.isCurrent(second))
  }

  func testStaleHideDoesNotOrderOut() {
    // The first message's fade-out has started (its hide check passed) when
    // the second one shows; the fade-out's completion must not order out.
    var visibility = HUDVisibility()
    let first = visibility.show()
    XCTAssertTrue(visibility.isCurrent(first))
    let second = visibility.show()
    XCTAssertFalse(visibility.isCurrent(first))
    XCTAssertTrue(visibility.isCurrent(second))
  }
}
