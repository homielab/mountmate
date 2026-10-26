//  Created by homielab.com

import Carbon
import XCTest

@testable import MountMate

final class HotkeyShortcutTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "com.homielab.mountmate.tests.hotkey.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  // MARK: - Model

  func testModifiersAreReducedToTheFourAllowedFlags() {
    let shortcut = HotkeyShortcut(
      keyCode: UInt16(kVK_ANSI_U),
      modifiers: [.command, .shift, .capsLock, .function, .numericPad])
    XCTAssertEqual(shortcut.modifiers, [.command, .shift])
  }

  func testAllFourModifiersAreKept() {
    let all: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    XCTAssertEqual(HotkeyShortcut(keyCode: 0, modifiers: all).modifiers, all)
  }

  func testCarbonModifiersMapping() {
    func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
      HotkeyShortcut(keyCode: 0, modifiers: flags).carbonModifiers
    }
    XCTAssertEqual(carbon([]), 0)
    XCTAssertEqual(carbon(.command), UInt32(cmdKey))
    XCTAssertEqual(carbon(.option), UInt32(optionKey))
    XCTAssertEqual(carbon(.control), UInt32(controlKey))
    XCTAssertEqual(carbon(.shift), UInt32(shiftKey))
    XCTAssertEqual(
      carbon([.command, .shift]), UInt32(cmdKey) | UInt32(shiftKey))
    XCTAssertEqual(
      carbon([.command, .option, .control, .shift]),
      UInt32(cmdKey | optionKey | controlKey | shiftKey))
  }

  func testShortcutsWithoutCommandOrControlAreUnsafe() {
    XCTAssertFalse(
      HotkeyShortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: .option).isSafeAsGlobalHotKey)
    XCTAssertFalse(
      HotkeyShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: .shift).isSafeAsGlobalHotKey)
    XCTAssertFalse(HotkeyShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: []).isSafeAsGlobalHotKey)
    XCTAssertFalse(
      HotkeyShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.option, .shift])
        .isSafeAsGlobalHotKey)
  }

  func testShortcutsWithCommandOrControlAreSafe() {
    XCTAssertTrue(
      HotkeyShortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: .command).isSafeAsGlobalHotKey)
    XCTAssertTrue(
      HotkeyShortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: .control).isSafeAsGlobalHotKey)
    XCTAssertTrue(HotkeyShortcut.defaultUnmount.isSafeAsGlobalHotKey)
    XCTAssertTrue(HotkeyShortcut.defaultMount.isSafeAsGlobalHotKey)
  }

  func testDisplayStringOrdersModifiersAndUsesSpecialKeys() {
    XCTAssertEqual(
      HotkeyShortcut(keyCode: UInt16(kVK_Space), modifiers: [.shift, .control, .option, .command])
        .displayString,
      "⌘⌥⌃⇧Space")
    XCTAssertEqual(
      HotkeyShortcut(keyCode: UInt16(kVK_F5), modifiers: .command).displayString, "⌘F5")
    XCTAssertEqual(
      HotkeyShortcut(keyCode: UInt16(kVK_Return), modifiers: []).displayString, "↩")
  }

  func testDefaultShortcutsAreDistinct() {
    XCTAssertNotEqual(HotkeyShortcut.defaultUnmount, HotkeyShortcut.defaultMount)
    XCTAssertEqual(HotkeyShortcut.defaultUnmount.modifiers, [.command, .option, .shift])
    XCTAssertEqual(HotkeyShortcut.defaultMount.modifiers, [.command, .shift])
  }

  // MARK: - Persistence

  func testMissingKeysFallBackToDefaults() {
    let manager = HotkeyManager(defaults: defaults)
    XCTAssertEqual(manager.unmountShortcut, .defaultUnmount)
    XCTAssertEqual(manager.mountShortcut, .defaultMount)
    XCTAssertEqual(manager.shortcut(for: .unmountAll), .defaultUnmount)
    XCTAssertEqual(manager.shortcut(for: .mountAll), .defaultMount)
  }

  func testEjectAllHasNoDefaultShortcutAndRegistersNothing() {
    let manager = HotkeyManager(defaults: defaults)
    XCTAssertNil(manager.shortcut(for: .ejectAll))
    XCTAssertNil(manager.ejectShortcut)
  }

  func testEjectAllShortcutRoundTripsAndCanBeCleared() {
    let eject = HotkeyShortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command, .option])
    let manager = HotkeyManager(defaults: defaults)
    manager.setShortcut(eject, for: .ejectAll)
    XCTAssertEqual(manager.shortcut(for: .ejectAll), eject)
    XCTAssertEqual(HotkeyManager(defaults: defaults).ejectShortcut, eject)
    XCTAssertEqual(manager.shortcut(for: .unmountAll), .defaultUnmount)

    manager.clearShortcut(for: .ejectAll)
    XCTAssertNil(manager.shortcut(for: .ejectAll))
    XCTAssertNil(HotkeyManager(defaults: defaults).ejectShortcut)
  }

  func testClearingMountAllKeepsItsShortcut() {
    let manager = HotkeyManager(defaults: defaults)
    manager.clearShortcut(for: .mountAll)
    XCTAssertEqual(manager.shortcut(for: .mountAll), .defaultMount)
  }

  func testSetShortcutRoundTripsThroughDefaults() {
    let unmount = HotkeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .control])
    let mount = HotkeyShortcut(keyCode: UInt16(kVK_F6), modifiers: [.command, .option])
    let manager = HotkeyManager(defaults: defaults)
    manager.setShortcut(unmount, for: .unmountAll)
    manager.setShortcut(mount, for: .mountAll)

    XCTAssertEqual(manager.shortcut(for: .unmountAll), unmount)
    XCTAssertEqual(manager.shortcut(for: .mountAll), mount)

    let reloaded = HotkeyManager(defaults: defaults)
    XCTAssertEqual(reloaded.unmountShortcut, unmount)
    XCTAssertEqual(reloaded.mountShortcut, mount)
  }

  func testSetShortcutWritesExpectedKeys() {
    let manager = HotkeyManager(defaults: defaults)
    manager.setShortcut(
      HotkeyShortcut(keyCode: 40, modifiers: [.command, .shift]), for: .unmountAll)
    XCTAssertEqual(defaults.integer(forKey: "hotkeyUnmountKeyCode"), 40)
    XCTAssertEqual(
      defaults.integer(forKey: "hotkeyUnmountModifiers"),
      Int(NSEvent.ModifierFlags([.command, .shift]).rawValue))
    XCTAssertNil(defaults.object(forKey: "hotkeyMountKeyCode"))
  }

  func testChangingOneActionLeavesTheOtherAtDefault() {
    let manager = HotkeyManager(defaults: defaults)
    manager.setShortcut(
      HotkeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: .command), for: .mountAll)
    XCTAssertEqual(manager.unmountShortcut, .defaultUnmount)
    XCTAssertEqual(HotkeyManager(defaults: defaults).unmountShortcut, .defaultUnmount)
  }

  func testStoredModifiersOutsideTheAllowedSetAreStripped() {
    let raw = NSEvent.ModifierFlags([.command, .capsLock, .function]).rawValue
    defaults.set(Int(kVK_ANSI_J), forKey: "hotkeyMountKeyCode")
    defaults.set(Int(raw), forKey: "hotkeyMountModifiers")
    let manager = HotkeyManager(defaults: defaults)
    XCTAssertEqual(manager.mountShortcut.keyCode, UInt16(kVK_ANSI_J))
    XCTAssertEqual(manager.mountShortcut.modifiers, .command)
  }

  func testIncompleteStoredShortcutFallsBack() {
    defaults.set(Int(kVK_ANSI_J), forKey: "hotkeyMountKeyCode")  // modifiers missing
    XCTAssertEqual(HotkeyManager(defaults: defaults).mountShortcut, .defaultMount)
  }

  func testOutOfRangeStoredKeyCodeIsClamped() {
    defaults.set(-5, forKey: "hotkeyUnmountKeyCode")
    defaults.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: "hotkeyUnmountModifiers")
    XCTAssertEqual(HotkeyManager(defaults: defaults).unmountShortcut.keyCode, 0)
  }
}
