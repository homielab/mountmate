//  Created by homielab.com

import AppKit
import XCTest

@testable import MountMate

final class RefreshQoSTests: XCTestCase {
  func testPlugInAppearanceAndWakeRefreshAtUserInitiated() {
    XCTAssertEqual(DriveManager.refreshQoS(for: NSWorkspace.didMountNotification), .userInitiated)
    XCTAssertEqual(DriveManager.refreshQoS(for: .diskAppearanceDidChange), .userInitiated)
    XCTAssertEqual(DriveManager.refreshQoS(for: NSWorkspace.didWakeNotification), .userInitiated)
  }

  func testUnmountRefreshesAtUtility() {
    XCTAssertEqual(DriveManager.refreshQoS(for: NSWorkspace.didUnmountNotification), .utility)
  }

  func testNoNotificationRefreshesAtBackground() {
    let names: [Notification.Name] = [
      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
      .diskAppearanceDidChange, NSWorkspace.didWakeNotification,
    ]
    for name in names {
      XCTAssertNotEqual(DriveManager.refreshQoS(for: name), .background, name.rawValue)
    }
  }

  func testCoalescedNotificationsKeepTheHighestQoS() {
    XCTAssertEqual(DriveManager.coalescedRefreshQoS(nil, .utility), .utility)
    XCTAssertEqual(DriveManager.coalescedRefreshQoS(nil, .userInitiated), .userInitiated)
    XCTAssertEqual(DriveManager.coalescedRefreshQoS(.utility, .userInitiated), .userInitiated)
    XCTAssertEqual(DriveManager.coalescedRefreshQoS(.userInitiated, .utility), .userInitiated)
    XCTAssertEqual(DriveManager.coalescedRefreshQoS(.utility, .utility), .utility)
  }

  func testUnmountThenMountBurstRefreshesAtUserInitiated() {
    let burst = [NSWorkspace.didUnmountNotification, NSWorkspace.didMountNotification]
    let qos = burst.reduce(nil as DispatchQoS.QoSClass?) { pending, name in
      DriveManager.coalescedRefreshQoS(pending, DriveManager.refreshQoS(for: name))
    }
    XCTAssertEqual(qos, .userInitiated)
  }
}
