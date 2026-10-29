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

  func testNetworkShareActionsConflictWithEveryOtherAction() throws {
    let suite = "HotkeyConflictRulesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = HotkeyManager(defaults: defaults)
    let cmdOptN = HotkeyShortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command, .option])

    XCTAssertEqual(manager.setShortcut(.defaultUnmount, for: .unmountAllShares), .unmountAll)
    XCTAssertNil(manager.setShortcut(cmdOptM, for: .ejectAll))
    XCTAssertEqual(manager.setShortcut(cmdOptM, for: .mountAllShares), .ejectAll)
    XCTAssertNil(manager.setShortcut(cmdOptN, for: .mountAllShares))
    XCTAssertEqual(manager.setShortcut(cmdOptN, for: .unmountAllShares), .mountAllShares)
    XCTAssertEqual(manager.setShortcut(cmdOptN, for: .mountAll), .mountAllShares)
    XCTAssertNil(manager.shortcut(for: .unmountAllShares))
    XCTAssertEqual(manager.shortcut(for: .mountAll), .defaultMount)
  }

  func testDuplicateShareShortcutKeepsTheEarlierAction() {
    let assigned: [HotkeyAction: HotkeyShortcut] = [
      .unmountAll: .defaultUnmount, .mountAll: cmdShiftM, .mountAllShares: cmdOptM,
      .unmountAllShares: cmdOptM,
    ]
    XCTAssertEqual(
      HotkeyConflictRules.duplicates(among: assigned), [.unmountAllShares: .mountAllShares])
  }
}
