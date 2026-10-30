//  Created by homielab.com

import XCTest

@testable import MountMate

final class StaleMountRulesTests: XCTestCase {
  func testNoAnswerOrADeadConnectionIsStale() {
    XCTAssertTrue(StaleMountRules.isStale(.timedOut))
    XCTAssertTrue(StaleMountRules.isStale(.failed(errno: ESTALE)))
    XCTAssertTrue(StaleMountRules.isStale(.failed(errno: ENOTCONN)))
    XCTAssertTrue(StaleMountRules.isStale(.failed(errno: EIO)))
  }

  func testAnAnswerIsNotStaleEvenWhenItIsAnError() {
    XCTAssertFalse(StaleMountRules.isStale(.responding))
    XCTAssertFalse(StaleMountRules.isStale(.failed(errno: EACCES)))
    XCTAssertFalse(StaleMountRules.isStale(.failed(errno: ENOENT)))
  }

  func testOnlyMountMatesOwnMountIsProbed() {
    let own = "/Users/me/mountmate/Media"
    XCTAssertEqual(
      StaleMountRules.probeTarget(
        mountPoint: own + "/", configuredMountPoint: own, isSuppressed: false,
        isCredentialRejected: false), own + "/")
    XCTAssertNil(
      StaleMountRules.probeTarget(
        mountPoint: "/Volumes/Media", configuredMountPoint: own, isSuppressed: false,
        isCredentialRejected: false), "the user's own Finder mount is left alone")
    XCTAssertNil(
      StaleMountRules.probeTarget(
        mountPoint: nil, configuredMountPoint: own, isSuppressed: false,
        isCredentialRejected: false))
  }

  func testSuppressedOrRejectedSharesAreNotProbed() {
    let own = "/Users/me/mountmate/Media"
    XCTAssertNil(
      StaleMountRules.probeTarget(
        mountPoint: own, configuredMountPoint: own, isSuppressed: true,
        isCredentialRejected: false))
    XCTAssertNil(
      StaleMountRules.probeTarget(
        mountPoint: own, configuredMountPoint: own, isSuppressed: false,
        isCredentialRejected: true))
  }

  func testLowPowerModeDoublesTheSweepInterval() {
    for interval in KeepAliveManager.allowedRetryIntervals {
      XCTAssertEqual(
        StaleMountRules.sweepInterval(retryInterval: interval, isLowPowerMode: false), interval)
      XCTAssertEqual(
        StaleMountRules.sweepInterval(retryInterval: interval, isLowPowerMode: true), interval * 2)
    }
  }

  func testAStaleShareThatCannotBeUnmountedIsStillDown() {
    XCTAssertFalse(StaleMountRules.remountResultWhenStillMounted(isStale: true))
    XCTAssertTrue(StaleMountRules.remountResultWhenStillMounted(isStale: false))
  }
}
