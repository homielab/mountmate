//  Created by homielab.com

import XCTest

@testable import MountMate

/// Folders the custom mount point editor creates, and their removal when the
/// save is cancelled or fails.
final class CreatedMountPointFoldersTests: XCTestCase {
  private var root = ""

  override func setUpWithError() throws {
    try super.setUpWithError()
    root =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("CreatedMountPointFoldersTests-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: root)
    try super.tearDownWithError()
  }

  private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

  /// What the editor does: list the missing folders, create them, then the
  /// save finishes with `result`.
  private func createAndFinish(
    _ path: String, result: PersistenceManager.CustomMountPointUpdateResult,
    mountTable: [MountEntry]? = [], beforeFinish: () throws -> Void = {}
  ) throws -> [String] {
    let editor = CustomMountPointEditorState()
    let folders = CreatedMountPointFolders.missing(for: path, exists: exists)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    editor.recordCreatedFolders(folders, for: "vol-1")
    try beforeFinish()
    return CreatedMountPointFolders.remove(
      editor.foldersToRemove(afterSaveOf: "vol-1", result: result),
      mountTable: mountTable, exists: exists, isMountPoint: { _ in false },
      removeEmptyFolder: { rmdir($0) == 0 })
  }

  func testMissingListsThePathAndEachMissingParentDeepestFirst() {
    let path = "\(root)/a/b/c"
    XCTAssertEqual(
      CreatedMountPointFolders.missing(for: path, exists: exists),
      ["\(root)/a/b/c", "\(root)/a/b", "\(root)/a"])
    XCTAssertEqual(CreatedMountPointFolders.missing(for: root, exists: exists), [])
  }

  func testCancelledSaveRemovesTheCreatedFoldersButNotTheExistingParent() throws {
    let path = "\(root)/mountmate/Backup"
    let removed = try createAndFinish(path, result: .cancelled)
    XCTAssertEqual(removed, [path, "\(root)/mountmate"])
    XCTAssertFalse(exists("\(root)/mountmate"))
    XCTAssertTrue(exists(root), "a folder that existed before is never removed")
  }

  func testFailedSaveRemovesTheCreatedFolder() throws {
    let path = "\(root)/Backup"
    _ = try createAndFinish(path, result: .failure("no"))
    XCTAssertFalse(exists(path))
  }

  func testSavedRuleKeepsTheCreatedFolder() throws {
    let path = "\(root)/Backup"
    XCTAssertEqual(try createAndFinish(path, result: .success), [])
    XCTAssertTrue(exists(path))
  }

  func testFolderThatGotContentsIsKeptWithItsParents() throws {
    let path = "\(root)/mountmate/Backup"
    let removed = try createAndFinish(path, result: .cancelled) {
      try Data("x".utf8).write(to: URL(fileURLWithPath: "\(path)/file.txt"))
    }
    XCTAssertEqual(removed, [])
    XCTAssertTrue(exists("\(path)/file.txt"))
  }

  func testExistingFolderIsNeverRemoved() throws {
    let path = "\(root)/Existing"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    XCTAssertEqual(try createAndFinish(path, result: .cancelled), [])
    XCTAssertTrue(exists(path))
  }

  func testFolderInTheMountTableOrUnreadableTableIsKept() throws {
    let mounted = "\(root)/Mounted"
    let entry = MountEntry(source: "/dev/disk9s1", mountPoint: mounted, fileSystemType: "apfs")
    XCTAssertEqual(try createAndFinish(mounted, result: .cancelled, mountTable: [entry]), [])
    XCTAssertTrue(exists(mounted))

    let unreadable = "\(root)/Unreadable"
    XCTAssertEqual(try createAndFinish(unreadable, result: .cancelled, mountTable: nil), [])
    XCTAssertTrue(exists(unreadable))
  }

  func testParentCreatedBeforeAFailedCreateIsRemoved() {
    // createDirectory made the parent, then failed on the folder itself.
    let parent = "\(root)/mountmate"
    let folders = CreatedMountPointFolders.missing(for: "\(parent)/Backup", exists: exists)
    XCTAssertNoThrow(
      try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false))
    XCTAssertEqual(
      CreatedMountPointFolders.remove(
        folders, mountTable: [], exists: exists, isMountPoint: { _ in false },
        removeEmptyFolder: { rmdir($0) == 0 }),
      [parent])
  }
}
