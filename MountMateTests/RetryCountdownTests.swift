//  Created by homielab.com

import XCTest

@testable import MountMate

final class RetryCountdownTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  func testNothingScheduledOrAlreadyDueShowsNoCountdown() {
    XCTAssertNil(RetryCountdown.remaining(next: nil, now: now))
    XCTAssertNil(RetryCountdown.remaining(next: now, now: now))
    XCTAssertNil(RetryCountdown.remaining(next: now.addingTimeInterval(-5), now: now))
  }

  func testSecondsAreRoundedUp() {
    XCTAssertEqual(
      RetryCountdown.remaining(next: now.addingTimeInterval(0.2), now: now), .seconds(1))
    XCTAssertEqual(
      RetryCountdown.remaining(next: now.addingTimeInterval(12.4), now: now), .seconds(13))
    XCTAssertEqual(
      RetryCountdown.remaining(next: now.addingTimeInterval(59), now: now), .seconds(59))
  }

  func testAMinuteOrMoreSwitchesToMinutesRoundedUp() {
    XCTAssertEqual(
      RetryCountdown.remaining(next: now.addingTimeInterval(60), now: now), .minutes(1))
    XCTAssertEqual(
      RetryCountdown.remaining(next: now.addingTimeInterval(61), now: now), .minutes(2))
    XCTAssertEqual(
      RetryCountdown.remaining(next: now.addingTimeInterval(240), now: now), .minutes(4))
  }

  func testTextIsPluralAwareInEveryLanguage() throws {
    func text(_ language: String, _ seconds: TimeInterval) throws -> String? {
      let path = try XCTUnwrap(
        Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"))
      return RetryCountdown.text(
        next: now.addingTimeInterval(seconds), now: now, bundle: try XCTUnwrap(Bundle(path: path)),
        locale: Locale(identifier: language))
    }
    XCTAssertEqual(try text("en", 1), "Retrying in 1 second")
    XCTAssertEqual(try text("en", 30), "Retrying in 30 seconds")
    XCTAssertEqual(try text("en", 120), "Retrying in 2 minutes")
    XCTAssertEqual(try text("vi", 30), "Thử lại sau 30 giây")
    XCTAssertEqual(try text("ru", 22), "Повтор через 22 секунды")
    XCTAssertEqual(try text("uk", 5), "Повтор через 5 секунд")
    XCTAssertEqual(try text("fr", 1), "Nouvelle tentative dans 1 seconde")
    XCTAssertEqual(try text("zh-Hans", 7), "7 秒后重试")
    XCTAssertEqual(try text("zh-Hant", 180), "3 分鐘後重試")
    XCTAssertNil(try text("en", 0))
  }

  func testTickerRunsOnlyBetweenStartAndStop() {
    let ticker = CountdownTicker()
    XCTAssertFalse(ticker.isRunning)
    ticker.start()
    ticker.start()
    XCTAssertTrue(ticker.isRunning)
    ticker.stop()
    XCTAssertFalse(ticker.isRunning)
    ticker.stop()
    XCTAssertFalse(ticker.isRunning)
  }
}
