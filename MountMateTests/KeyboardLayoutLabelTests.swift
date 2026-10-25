//  Created by homielab.com

import Carbon
import XCTest

@testable import MountMate

final class KeyboardLayoutLabelTests: XCTestCase {
  private struct FakeLayout: KeyboardLayoutProviding {
    let map: [Int: String]
    func character(for keyCode: UInt16) -> String? { map[Int(keyCode)] }
  }

  private let azerty = FakeLayout(map: [kVK_ANSI_Q: "a", kVK_ANSI_A: "q", kVK_ANSI_M: ","])
  private let cyrillic = FakeLayout(map: [kVK_ANSI_U: "г"])
  private let none = FakeLayout(map: [:])

  func testUSFallbackWhenLayoutCannotTranslate() {
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_ANSI_U), layout: none), "U")
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_ANSI_Slash), layout: none), "/")
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: 0x7F, layout: none), "Key 127")
  }

  func testLabelsFollowTheLayout() {
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_ANSI_Q), layout: azerty), "A")
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_ANSI_M), layout: azerty), ",")
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_ANSI_U), layout: cyrillic), "Г")
    // Keys the layout does not translate keep the US label.
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_ANSI_B), layout: azerty), "B")
  }

  func testSpecialKeysIgnoreTheLayout() {
    let odd = FakeLayout(map: [kVK_Return: "x", kVK_F1: "y", kVK_Space: "z"])
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_Return), layout: odd), "↩")
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_F1), layout: odd), "F1")
    XCTAssertEqual(HotkeyShortcut.keyLabel(for: UInt16(kVK_Space), layout: odd), "Space")
  }

  /// Reads the data of installed layouts without selecting them.
  private func layoutData(id: String) -> Data? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard
      let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
        as? [TISInputSource],
      let source = list.first,
      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
  }

  func testUCKeyTranslateWithInstalledLayouts() throws {
    let us = try XCTUnwrap(layoutData(id: "com.apple.keylayout.US"))
    XCTAssertEqual(SystemKeyboardLayout.translate(keyCode: UInt16(kVK_ANSI_Q), layoutData: us), "q")
    if let french = layoutData(id: "com.apple.keylayout.French") {
      XCTAssertEqual(
        SystemKeyboardLayout.translate(keyCode: UInt16(kVK_ANSI_Q), layoutData: french), "a")
    }
    if let dvorak = layoutData(id: "com.apple.keylayout.Dvorak") {
      XCTAssertEqual(
        SystemKeyboardLayout.translate(keyCode: UInt16(kVK_ANSI_S), layoutData: dvorak), "o")
    }
    XCTAssertNil(SystemKeyboardLayout.translate(keyCode: UInt16(kVK_Return), layoutData: us))
  }
}
