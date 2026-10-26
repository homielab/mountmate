import XCTest

@testable import MountMate

final class FullDiskAccessCheckerTests: XCTestCase {
  func testGrantedWhenProbeSucceeds() {
    var probed: String?
    let granted = FullDiskAccessChecker.isGranted { probed = $0 }
    XCTAssertTrue(granted)
    XCTAssertEqual(probed, FullDiskAccessChecker.probePath)
  }

  func testNotGrantedWhenProbeThrows() {
    let denied = CocoaError(.fileReadNoPermission)
    XCTAssertFalse(FullDiskAccessChecker.isGranted { _ in throw denied })
  }

  func testSettingsURLPointsAtFullDiskAccessPane() {
    XCTAssertEqual(
      FullDiskAccessChecker.settingsURL?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
  }
}
