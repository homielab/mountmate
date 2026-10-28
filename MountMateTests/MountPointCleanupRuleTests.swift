//  Created by homielab.com

import XCTest

@testable import MountMate

final class MountPointCleanupRuleTests: XCTestCase {
  func testNeverRemovesWhenTableUnreadable() {
    XCTAssertFalse(
      MountPointCleanupRule.shouldRemove(
        created: true, tableReadable: false, inMountTable: false, isMountPoint: false))
  }

  func testNeverRemovesWhenNotCreatedByUs() {
    XCTAssertFalse(
      MountPointCleanupRule.shouldRemove(
        created: false, tableReadable: true, inMountTable: false, isMountPoint: false))
  }

  func testNeverRemovesWhenInMountTable() {
    XCTAssertFalse(
      MountPointCleanupRule.shouldRemove(
        created: true, tableReadable: true, inMountTable: true, isMountPoint: false))
  }

  func testNeverRemovesWhenIsMountPoint() {
    XCTAssertFalse(
      MountPointCleanupRule.shouldRemove(
        created: true, tableReadable: true, inMountTable: false, isMountPoint: true))
  }

  func testRemovesOnlyWhenAllClear() {
    for created in [false, true] {
      for tableReadable in [false, true] {
        for inMountTable in [false, true] {
          for isMountPoint in [false, true] {
            let expected = created && tableReadable && !inMountTable && !isMountPoint
            XCTAssertEqual(
              MountPointCleanupRule.shouldRemove(
                created: created, tableReadable: tableReadable,
                inMountTable: inMountTable, isMountPoint: isMountPoint),
              expected,
              "created=\(created) tableReadable=\(tableReadable) inMountTable=\(inMountTable) isMountPoint=\(isMountPoint)"
            )
          }
        }
      }
    }
  }

  /// The mount point check stats the folder, which can hang on a live
  /// network share: it must not run when the mount table lists the folder.
  func testDoesNotCheckForMountPointWhenInMountTable() {
    var checked = false
    _ = MountPointCleanupRule.shouldRemove(
      created: true, tableReadable: true, inMountTable: true,
      isMountPoint: {
        checked = true
        return false
      }())
    XCTAssertFalse(checked)
  }
}
