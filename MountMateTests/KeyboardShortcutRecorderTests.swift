//  Created by homielab.com

import AppKit
import Carbon
import XCTest

@testable import MountMate

/// The shortcut recorder starts recording from the keyboard and VoiceOver,
/// not only from a mouse click.
@MainActor
final class KeyboardShortcutRecorderTests: XCTestCase {
  private func key(_ keyCode: Int) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
        keyCode: UInt16(keyCode)))
  }

  private func recorder(recording: @escaping (Bool) -> Void) -> ShortcutRecorderButton {
    let button = ShortcutRecorderButton()
    button.recorderLabel = "Mount All Volumes"
    button.onRecordingChanged = recording
    return button
  }

  func testSpaceReturnAndEnterStartRecording() throws {
    for keyCode in [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter] {
      var started = false
      let button = recorder { started = $0 }
      button.keyDown(with: try key(keyCode))
      XCTAssertTrue(started, "key code \(keyCode)")
    }
  }

  func testVoiceOverPressAndButtonActionStartRecording() {
    var presses = 0
    let button = recorder { if $0 { presses += 1 } }
    XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertTrue(button.sendAction(button.action, to: button.target))
    XCTAssertEqual(presses, 2)
  }

  func testAccessibilityLabelNamesTheActionAndValueIsTheShortcut() {
    let button = recorder { _ in }
    XCTAssertEqual(
      button.accessibilityLabel(),
      AccessibilityLabels.shortcutRecorder(name: "Mount All Volumes"))
    XCTAssertEqual(button.accessibilityValue() as? String, button.title)
  }
}
