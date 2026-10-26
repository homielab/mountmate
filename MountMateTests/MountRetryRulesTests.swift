//  Created by homielab.com

import XCTest

@testable import MountMate

final class MountRetryRulesTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private let failedMount = "Volume Data on disk4s1 failed to mount; Error: -69842"

  private func result(
    stdout: String = "", stderr: String = "", exitCode: Int32? = 1, timedOut: Bool = false
  ) -> ProcessResult {
    ProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut)
  }

  private func retry(_ result: ProcessResult, firstSeenAgo: TimeInterval?) -> Bool {
    MountRetryRules.shouldRetry(
      after: result, firstSeen: firstSeenAgo.map { now.addingTimeInterval(-$0) }, now: now,
      window: 20)
  }

  func testRetriesRecentGenericMountFailure() {
    XCTAssertTrue(retry(result(stderr: failedMount), firstSeenAgo: 3))
  }

  func testRetriesWhenVolumeNotListedYet() {
    XCTAssertTrue(retry(result(stderr: failedMount), firstSeenAgo: nil))
  }

  func testDoesNotRetryOldVolumeOrBoundary() {
    XCTAssertFalse(retry(result(stderr: failedMount), firstSeenAgo: 60))
    XCTAssertFalse(retry(result(stderr: failedMount), firstSeenAgo: 20))
    XCTAssertTrue(retry(result(stderr: failedMount), firstSeenAgo: 19.9))
  }

  func testDoesNotRetrySuccess() {
    XCTAssertFalse(retry(result(exitCode: 0), firstSeenAgo: 1))
  }

  func testDoesNotRetryTimeout() {
    XCTAssertFalse(
      retry(result(stderr: failedMount, exitCode: nil, timedOut: true), firstSeenAgo: 1))
  }

  func testDoesNotRetryOtherErrors() {
    XCTAssertFalse(retry(result(stderr: "resource busy"), firstSeenAgo: 1))
    XCTAssertFalse(retry(result(stderr: ""), firstSeenAgo: 1))
  }

  func testDoesNotRetryPermanentMarkers() {
    for marker in ["unrecognized", "not supported", "unsupported", "corrupt"] {
      XCTAssertFalse(
        retry(result(stderr: "\(failedMount) (\(marker) file system)"), firstSeenAgo: 1), marker)
    }
  }

  func testGenericReadOnlyHintIsNotPermanent() {
    let hint = "\(failedMount). If the volume is damaged, try the \"readOnly\" option"
    XCTAssertTrue(retry(result(stderr: hint), firstSeenAgo: 1))
  }

  func testMatchingIsCaseInsensitive() {
    XCTAssertTrue(retry(result(stderr: failedMount.uppercased()), firstSeenAgo: 1))
    XCTAssertFalse(
      retry(result(stderr: "\(failedMount) UNSUPPORTED"), firstSeenAgo: 1))
  }

  func testDefaultWindowIsTwentySeconds() {
    XCTAssertEqual(MountRetryRules.recentAppearanceWindow, 20)
    XCTAssertTrue(
      MountRetryRules.shouldRetry(
        after: result(stderr: failedMount), firstSeen: now.addingTimeInterval(-19), now: now))
    XCTAssertFalse(
      MountRetryRules.shouldRetry(
        after: result(stderr: failedMount), firstSeen: now.addingTimeInterval(-21), now: now))
  }
}
