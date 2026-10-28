import XCTest

@testable import MountMate

final class SleepAllowGateTests: XCTestCase {
  /// Records the scheduled timeout instead of running it, so a test fires it
  /// when it wants.
  private final class ManualScheduler {
    var delays: [TimeInterval] = []
    var pending: [() -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
      delays.append(delay)
      pending.append(work)
    }

    func fire() {
      let work = pending
      pending.removeAll()
      for item in work { item() }
    }
  }

  private var scheduler: ManualScheduler!
  private var allowCount = 0
  private var timeoutCount = 0

  override func setUp() {
    super.setUp()
    scheduler = ManualScheduler()
    allowCount = 0
    timeoutCount = 0
  }

  private func makeGate(isEnabled: Bool = true) -> SleepAllowGate {
    SleepAllowGate(
      isEnabled: isEnabled, timeout: 20,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      onTimeout: { [unowned self] in timeoutCount += 1 },
      allow: { [unowned self] in allowCount += 1 })
  }

  func testCompletionBeforeTimeoutAllowsOnceAndSkipsTimeout() {
    let gate = makeGate()
    XCTAssertEqual(scheduler.delays, [20])
    XCTAssertEqual(allowCount, 0)

    gate.complete()
    XCTAssertEqual(allowCount, 1)
    XCTAssertTrue(gate.hasAllowed)

    scheduler.fire()
    XCTAssertEqual(allowCount, 1)
    XCTAssertEqual(timeoutCount, 0)
  }

  func testTimeoutBeforeCompletionReportsOnceThenAllowsAndIgnoresLateCompletion() {
    let gate = makeGate()

    scheduler.fire()
    XCTAssertEqual(timeoutCount, 1)
    XCTAssertEqual(allowCount, 1)

    gate.complete()
    gate.complete()
    XCTAssertEqual(timeoutCount, 1)
    XCTAssertEqual(allowCount, 1)
  }

  func testRepeatedCompletionAllowsOnlyOnce() {
    let gate = makeGate()
    gate.complete()
    gate.complete()
    XCTAssertEqual(allowCount, 1)
  }

  func testDisabledFeatureAllowsAtOnceWithoutTimer() {
    let gate = makeGate(isEnabled: false)
    XCTAssertEqual(allowCount, 1)
    XCTAssertTrue(scheduler.delays.isEmpty)
    XCTAssertTrue(gate.hasAllowed)

    gate.complete()
    XCTAssertEqual(allowCount, 1)
    XCTAssertEqual(timeoutCount, 0)
  }

  func testGateStaysAliveUntilTimeoutWhenCallerDropsIt() {
    _ = makeGate()
    scheduler.fire()
    XCTAssertEqual(timeoutCount, 1)
    XCTAssertEqual(allowCount, 1)
  }
}
