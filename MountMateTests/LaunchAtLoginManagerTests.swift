//  Created by homielab.com

import ServiceManagement
import XCTest

@testable import MountMate

final class LaunchAtLoginManagerTests: XCTestCase {
  func testEnabledAndWaitingForApprovalCountAsOn() {
    XCTAssertTrue(LaunchAtLoginManager.isOn(.enabled))
    XCTAssertTrue(LaunchAtLoginManager.isOn(.requiresApproval))
  }

  func testNotRegisteredAndNotFoundCountAsOff() {
    XCTAssertFalse(LaunchAtLoginManager.isOn(.notRegistered))
    XCTAssertFalse(LaunchAtLoginManager.isOn(.notFound))
  }
}
