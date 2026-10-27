//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeVerifierTests: XCTestCase {
  /// Thread-safe record of what the injected runner saw.
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(executable: String, arguments: [String], onMain: Bool)] = []

    func record(_ executable: String, _ arguments: [String]) {
      let onMain = Thread.isMainThread
      lock.withLock { entries.append((executable, arguments, onMain)) }
    }

    var all: [(executable: String, arguments: [String], onMain: Bool)] {
      lock.withLock { entries }
    }
  }

  private static let okResult = ProcessResult(
    stdout: "The volume Data appears to be OK.", stderr: "", exitCode: 0, timedOut: false)

  func testRunsDiskutilVerifyOffTheMainThreadAndCompletesOnMain() {
    let calls = Calls()
    let verifier = VolumeVerifier(timeout: 10) { executable, arguments, _ in
      calls.record(executable, arguments)
      return Self.okResult
    }
    let done = expectation(description: "completion")

    let started = verifier.verify(volumeID: "v1", deviceIdentifier: "disk9s2") { result in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(result, Self.okResult)
      done.fulfill()
    }

    XCTAssertTrue(started)
    wait(for: [done], timeout: 5)
    XCTAssertEqual(calls.all.count, 1)
    XCTAssertEqual(calls.all.first?.executable, "/usr/sbin/diskutil")
    XCTAssertEqual(calls.all.first?.arguments, ["verifyVolume", "disk9s2"])
    XCTAssertEqual(calls.all.first?.onMain, false)
    XCTAssertFalse(verifier.isVerifying("v1"))
  }

  func testPassesTheTimeoutToTheRunner() {
    let seen = expectation(description: "runner")
    let verifier = VolumeVerifier(timeout: 42) { _, _, timeout in
      XCTAssertEqual(timeout, 42)
      seen.fulfill()
      return Self.okResult
    }
    verifier.verify(volumeID: "v1", deviceIdentifier: "disk9s2") { _ in }
    wait(for: [seen], timeout: 5)
  }

  func testIgnoresASecondRunForTheSameVolumeUntilTheFirstFinishes() {
    let calls = Calls()
    let gate = DispatchSemaphore(value: 0)
    let firstStarted = expectation(description: "first started")
    let verifier = VolumeVerifier(timeout: 10) { executable, arguments, _ in
      calls.record(executable, arguments)
      if calls.all.count == 1 {
        firstStarted.fulfill()
        gate.wait()
      }
      return Self.okResult
    }
    let firstDone = expectation(description: "first done")

    XCTAssertTrue(
      verifier.verify(volumeID: "v1", deviceIdentifier: "disk9s2") { _ in firstDone.fulfill() })
    wait(for: [firstStarted], timeout: 5)
    XCTAssertTrue(verifier.isVerifying("v1"))
    XCTAssertFalse(verifier.verify(volumeID: "v1", deviceIdentifier: "disk9s2") { _ in })

    // Another volume may run at the same time.
    let otherDone = expectation(description: "other volume done")
    XCTAssertTrue(
      verifier.verify(volumeID: "v2", deviceIdentifier: "disk8s1") { _ in otherDone.fulfill() })
    wait(for: [otherDone], timeout: 5)

    gate.signal()
    wait(for: [firstDone], timeout: 5)
    XCTAssertEqual(calls.all.count, 2)

    // Finished: the same volume can be verified again.
    let againDone = expectation(description: "again done")
    XCTAssertTrue(
      verifier.verify(volumeID: "v1", deviceIdentifier: "disk9s2") { _ in againDone.fulfill() })
    wait(for: [againDone], timeout: 5)
    XCTAssertEqual(calls.all.count, 3)
  }
}
