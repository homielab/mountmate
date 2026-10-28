//  Created by homielab.com

import Foundation
import XCTest

@testable import MountMate

/// "Eject All Manually Connected Shares": every share is unmounted in
/// parallel and each failure keeps its translated reason.
final class ManualShareUnmountTests: XCTestCase {
  private typealias Target = NetworkMountManager.ShareUnmountTarget

  private let targets = [
    Target(name: "Media", mountPoint: "/Volumes/Media"),
    Target(name: "Backup", mountPoint: "/Volumes/Backup"),
    Target(name: "Photos", mountPoint: "/Volumes/Photos"),
  ]

  private func result(_ code: Int32?, stderr: String = "", timedOut: Bool = false)
    -> ProcessResult
  {
    ProcessResult(stdout: "", stderr: stderr, exitCode: code, timedOut: timedOut)
  }

  func testNoFailuresWhenEveryShareUnmounts() {
    let failures = NetworkMountManager.unmountShares(targets, force: false) { _, _ in
      self.result(0)
    }
    XCTAssertEqual(failures, [])
  }

  func testFailuresKeepTheirReasonAndWhetherForceMayHelpInOrder() {
    let failures = NetworkMountManager.unmountShares(targets, force: false) { target, _ in
      switch target.name {
      case "Media": self.result(nil, timedOut: true)
      case "Photos": self.result(1, stderr: "umount: /Volumes/Photos: not currently mounted")
      default: self.result(0)
      }
    }
    XCTAssertEqual(failures.map(\.target.name), ["Media", "Photos"])
    XCTAssertEqual(failures.map(\.failure.canForce), [true, false])
    XCTAssertTrue(failures[0].failure.message.contains("Media"))
    XCTAssertTrue(failures[1].failure.message.contains("Photos"))
  }

  func testTheForceFlagReachesEveryUmount() {
    final class Flags: @unchecked Sendable {
      private let lock = NSLock()
      private var values: [Bool] = []
      func add(_ value: Bool) { lock.withLock { values.append(value) } }
      var all: [Bool] { lock.withLock { values } }
    }
    let flags = Flags()
    _ = NetworkMountManager.unmountShares(targets, force: true) { _, force in
      flags.add(force)
      return self.result(0)
    }
    XCTAssertEqual(flags.all, [true, true, true])
  }

  func testOneHungShareDoesNotHoldUpTheOthers() throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.activeProcessorCount < 2, "needs two cores to run in parallel")
    // The first share's umount only returns once another share's umount has
    // run: one after the other, it would wait out the 5 s and fail.
    let otherRan = DispatchSemaphore(value: 0)
    let pair = Array(targets.prefix(2))
    let failures = NetworkMountManager.unmountShares(pair, force: false) { target, _ in
      if target.name == "Media" {
        return otherRan.wait(timeout: .now() + 5) == .success
          ? self.result(0) : self.result(nil, timedOut: true)
      }
      otherRan.signal()
      return self.result(0)
    }
    XCTAssertEqual(failures, [])
  }

  func testNothingToUnmountReturnsNothing() {
    XCTAssertEqual(
      NetworkMountManager.unmountShares([], force: false) { _, _ in self.result(1) }, [])
  }
}
