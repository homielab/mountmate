//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeListStateTests: XCTestCase {
  private func volume(id: String, name: String = "Backup") -> Volume {
    Volume(
      id: id, deviceIdentifier: "disk4s1", diskUUID: nil, name: name,
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "apfs", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  // MARK: - rowState(for:)

  func testVolumeWithoutRowStateGetsDefaults() {
    let state = VolumeListState(rowStates: ["other": VolumeRowState(isPinned: true)])
    XCTAssertEqual(state.rowState(for: volume(id: "missing")), VolumeRowState())
  }

  func testVolumeWithRowStateGetsItsOwnState() {
    var rowState = VolumeRowState()
    rowState.isKeepAlive = true
    rowState.customMountPoint = "/Volumes/Work"
    let state = VolumeListState(rowStates: ["vol-1": rowState])
    XCTAssertEqual(state.rowState(for: volume(id: "vol-1")), rowState)
  }

  // MARK: - isEditorExpanded(for:context:)

  func testPinnedRowExpandedDoesNotExpandDiskRowOfSameVolume() {
    let vol = volume(id: "vol-1")
    let state = VolumeListState(
      expandedEditorRowID: VolumeRowView.editorRowID(for: vol, context: .pinned))
    XCTAssertTrue(state.isEditorExpanded(for: vol, context: .pinned))
    XCTAssertFalse(state.isEditorExpanded(for: vol, context: .disk))
  }

  func testDiskRowExpandedDoesNotExpandPinnedRowOfSameVolume() {
    let vol = volume(id: "vol-1")
    let state = VolumeListState(
      expandedEditorRowID: VolumeRowView.editorRowID(for: vol, context: .disk))
    XCTAssertTrue(state.isEditorExpanded(for: vol, context: .disk))
    XCTAssertFalse(state.isEditorExpanded(for: vol, context: .pinned))
  }

  func testExpandedRowDoesNotExpandAnotherVolume() {
    let state = VolumeListState(
      expandedEditorRowID: VolumeRowView.editorRowID(for: volume(id: "vol-1"), context: .disk))
    XCTAssertFalse(state.isEditorExpanded(for: volume(id: "vol-2"), context: .disk))
  }

  func testNothingExpandedByDefault() {
    let state = VolumeListState()
    XCTAssertFalse(state.isEditorExpanded(for: volume(id: "vol-1"), context: .pinned))
    XCTAssertFalse(state.isEditorExpanded(for: volume(id: "vol-1"), context: .disk))
  }

  func testEditorRowIDsDifferPerContextAndVolume() {
    let first = volume(id: "vol-1")
    let ids: Set = [
      VolumeRowView.editorRowID(for: first, context: .pinned),
      VolumeRowView.editorRowID(for: first, context: .disk),
      VolumeRowView.editorRowID(for: volume(id: "vol-2"), context: .pinned),
      VolumeRowView.editorRowID(for: volume(id: "vol-2"), context: .disk),
    ]
    XCTAssertEqual(ids.count, 4)
  }
}
