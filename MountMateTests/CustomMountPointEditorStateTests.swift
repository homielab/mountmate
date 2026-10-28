//  Created by homielab.com

import XCTest

@testable import MountMate

final class CustomMountPointEditorStateTests: XCTestCase {
  /// An editor with every flag set, as if a save were half way through.
  private func busyEditor() -> CustomMountPointEditorState {
    let editor = CustomMountPointEditorState()
    editor.expandedRowID = "pinned:vol-1"
    editor.mountPointPath = "/Volumes/Typed"
    editor.inlineError = "Not a folder"
    editor.pendingSavePath = "/Volumes/Pending"
    editor.showCreateDirectoryAlert = true
    editor.showNonEmptyDirectoryAlert = true
    editor.isChoosingFolder = true
    editor.savingVolumeIDs = ["vol-1"]
    return editor
  }

  private func assertTransientStateCleared(
    _ editor: CustomMountPointEditorState, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertNil(editor.inlineError, file: file, line: line)
    XCTAssertNil(editor.pendingSavePath, file: file, line: line)
    XCTAssertFalse(editor.showCreateDirectoryAlert, file: file, line: line)
    XCTAssertFalse(editor.showNonEmptyDirectoryAlert, file: file, line: line)
    XCTAssertFalse(editor.isChoosingFolder, file: file, line: line)
  }

  // MARK: - sync(from:)

  func testSyncLoadsPersistedPathAndClearsErrorsAndAlerts() {
    let editor = busyEditor()
    editor.sync(from: "/Volumes/Work")
    XCTAssertEqual(editor.mountPointPath, "/Volumes/Work")
    assertTransientStateCleared(editor)
  }

  func testSyncWithoutPersistedPathEmptiesThePath() {
    let editor = busyEditor()
    editor.sync(from: nil)
    XCTAssertEqual(editor.mountPointPath, "")
  }

  func testSyncKeepsTheOpenRowAndRunningSaves() {
    let editor = busyEditor()
    editor.sync(from: nil)
    XCTAssertEqual(editor.expandedRowID, "pinned:vol-1")
    XCTAssertEqual(editor.savingVolumeIDs, ["vol-1"])
  }

  // MARK: - collapse()

  func testCollapseClosesTheRowAndClearsErrorsAndAlerts() {
    let editor = busyEditor()
    editor.collapse()
    XCTAssertNil(editor.expandedRowID)
    assertTransientStateCleared(editor)
  }

  func testCollapseKeepsRunningSaves() {
    let editor = busyEditor()
    editor.collapse()
    XCTAssertEqual(editor.savingVolumeIDs, ["vol-1"])
  }
}
