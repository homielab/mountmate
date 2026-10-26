//  Created by homielab.com

import XCTest

@testable import MountMate

final class RetryBookTests: XCTestCase {
  private var current = Date(timeIntervalSince1970: 1_000)

  private func makeBook() -> RetryBook<String> {
    RetryBook<String>(now: { self.current })
  }

  /// 10 s doubled per attempt.
  private let backoff: (Int) -> TimeInterval = { 10 * pow(2.0, Double($0 - 1)) }

  func testUnknownKeyIsDueWithNoAttempts() {
    let book = makeBook()
    XCTAssertTrue(book.isDue("a"))
    XCTAssertEqual(book.attempt(for: "a"), 0)
    XCTAssertNil(book.nextFireDate(for: "a"))
  }

  func testAttemptCountsAndSchedulesBackoff() {
    var book = makeBook()
    book.recordAttempt("a", backoff: backoff)
    XCTAssertEqual(book.attempt(for: "a"), 1)
    XCTAssertEqual(book.nextFireDate(for: "a"), current.addingTimeInterval(10))
    book.recordAttempt("a", backoff: backoff)
    XCTAssertEqual(book.attempt(for: "a"), 2)
    XCTAssertEqual(book.nextFireDate(for: "a"), current.addingTimeInterval(20))
    XCTAssertEqual(book.attempt(for: "b"), 0)
  }

  func testDueOnlyOnceBackoffElapsed() {
    var book = makeBook()
    book.recordAttempt("a", backoff: backoff)
    XCTAssertFalse(book.isDue("a"))
    current.addTimeInterval(9.9)
    XCTAssertFalse(book.isDue("a"))
    current.addTimeInterval(0.1)
    XCTAssertTrue(book.isDue("a"))
  }

  func testClearDelaysKeepsAttempts() {
    var book = makeBook()
    book.recordAttempt("a", backoff: backoff)
    book.recordAttempt("a", backoff: backoff)
    book.clearDelays()
    XCTAssertTrue(book.isDue("a"))
    XCTAssertNil(book.nextFireDate(for: "a"))
    XCTAssertEqual(book.attempt(for: "a"), 2)
  }

  func testRemoveAndRemoveAll() {
    var book = makeBook()
    book.recordAttempt("a", backoff: backoff)
    book.recordAttempt("b", backoff: backoff)
    book.remove("a")
    XCTAssertEqual(book.attempt(for: "a"), 0)
    XCTAssertEqual(book.attempt(for: "b"), 1)
    book.removeAll()
    XCTAssertEqual(book.attempt(for: "b"), 0)
  }

  func testPruneDropsOnlyKeysNotKept() {
    var book = makeBook()
    for key in ["a", "b", "c"] { book.recordAttempt(key, backoff: backoff) }
    let dropped = book.prune(keeping: ["b", "x"])
    XCTAssertEqual(dropped, ["a", "c"])
    XCTAssertEqual(book.attempt(for: "b"), 1)
    XCTAssertEqual(book.attempt(for: "a"), 0)
    XCTAssertTrue(book.prune(keeping: ["b"]).isEmpty)
  }
}
