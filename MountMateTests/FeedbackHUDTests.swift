//  Created by homielab.com

import XCTest

@testable import MountMate

final class FeedbackHUDTests: XCTestCase {
  func testFadeIsSkippedWhenReduceMotionIsOn() {
    XCTAssertEqual(FeedbackHUD.fadeDuration(0.18, reduceMotion: true), 0)
    XCTAssertEqual(FeedbackHUD.fadeDuration(0.3, reduceMotion: true), 0)
  }

  func testFadeKeepsItsLengthWhenReduceMotionIsOff() {
    XCTAssertEqual(FeedbackHUD.fadeDuration(0.18, reduceMotion: false), 0.18)
    XCTAssertEqual(FeedbackHUD.fadeDuration(0.3, reduceMotion: false), 0.3)
  }
}
