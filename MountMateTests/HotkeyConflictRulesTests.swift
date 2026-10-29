//  Created by homielab.com

import AppKit
import Carbon.HIToolbox
import XCTest

@testable import MountMate

final class HotkeyConflictRulesTests: XCTestCase {
  private let cmdShiftM = HotkeyShortcut(
    keyCode: UInt16(kVK_ANSI_M), modifiers: [.command, .shift])
  private let cmdOptM = HotkeyShortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.command, .option])

  func testSameKeyAndModifiersAsAnotherActionConflicts() {
    let assigned: [HotkeyAction: HotkeyShortcut] = [
      .unmountAll: .defaultUnmount, .mountAll: cmdShiftM,
    ]
    XCTAssertEqual(
      HotkeyConflictRules.conflict(for: cmdShiftM, assignedTo: .ejectAll, among: assigned),
      .mountAll)
    XCTAssertEqual(
      HotkeyConflictRules.conflict(
        for: .defaultUnmount, assignedTo: .ejectAll, among: assigned),
      .unmountAll)
  }

  func testDifferentModifiersDoNotConflict() {
    let assigned: [HotkeyAction: HotkeyShortcut] = [.mountAll: cmdShiftM]
    XCTAssertNil(HotkeyConflictRules.conflict(for: cmdOptM, assignedTo: .ejectAll, among: assigned))
  }

  func testReassigningOwnShortcutDoesNotConflict() {
    let assigned: [HotkeyAction: HotkeyShortcut] = [.mountAll: cmdShiftM]
    XCTAssertNil(
      HotkeyConflictRules.conflict(for: cmdShiftM, assignedTo: .mountAll, among: assigned))
  }

  func testDuplicatesKeepTheFirstAction() {
    let assigned: [HotkeyAction: HotkeyShortcut] = [
      .unmountAll: .defaultUnmount, .mountAll: cmdShiftM, .ejectAll: cmdShiftM,
    ]
    XCTAssertEqual(HotkeyConflictRules.duplicates(among: assigned), [.ejectAll: .mountAll])
    XCTAssertEqual(
      HotkeyConflictRules.duplicates(among: [.unmountAll: .defaultUnmount, .mountAll: cmdShiftM]),
      [:])
  }

  func testManagerRefusesShortcutOfAnotherAction() throws {
    let suite = "HotkeyConflictRulesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = HotkeyManager(defaults: defaults)

    XCTAssertEqual(manager.setShortcut(.defaultMount, for: .ejectAll), .mountAll)
    XCTAssertNil(manager.shortcut(for: .ejectAll))
    XCTAssertNil(manager.setShortcut(cmdOptM, for: .ejectAll))
    XCTAssertEqual(manager.shortcut(for: .ejectAll), cmdOptM)
  }
}
