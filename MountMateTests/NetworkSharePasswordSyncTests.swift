//  Created by homielab.com

import Security
import XCTest

@testable import MountMate

private final class FakePasswordStore: PasswordStore {
  var saved: [(password: String, account: String, name: String)] = []
  var deleted: [String] = []
  var saveStatus: OSStatus = errSecSuccess
  var deleteStatus: OSStatus = errSecSuccess
  var relabeled: [(account: String, name: String)] = []
  var relabelStatus: OSStatus = errSecSuccess

  func save(password: String, for account: String, name: String, kind: KeychainItemKind)
    -> OSStatus
  {
    saved.append((password, account, name))
    return saveStatus
  }

  func delete(account: String) -> OSStatus {
    deleted.append(account)
    return deleteStatus
  }

  func updateLabel(for account: String, name: String, kind: KeychainItemKind) -> OSStatus {
    relabeled.append((account, name))
    return relabelStatus
  }
}

final class NetworkSharePasswordSyncTests: XCTestCase {
  private func share(
    id: UUID = UUID(), name: String = "Media", server: String = "nas.local",
    username: String = "me", proto: ShareProtocol = .smb
  ) -> NetworkShare {
    NetworkShare(
      id: id, name: name, server: server, sharePath: "media", username: username,
      mountAtLogin: true, keepMounted: true, shareProtocol: proto, customMountPoint: nil)
  }

  func testNewShareWithPasswordIsSavedUnderItsID() {
    let store = FakePasswordStore()
    let new = share()
    let error = NetworkSharePasswordSync(store: store).sync(
      share: new, original: nil, password: "secret", loadedPassword: nil)
    XCTAssertNil(error)
    XCTAssertEqual(store.saved.count, 1)
    XCTAssertEqual(store.saved.first?.account, new.id.uuidString)
    XCTAssertEqual(store.saved.first?.password, "secret")
    XCTAssertEqual(store.saved.first?.name, "Media")
    XCTAssertTrue(store.deleted.isEmpty)
  }

  func testNewShareWithoutPasswordTouchesNothing() {
    let store = FakePasswordStore()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: share(), original: nil, password: "", loadedPassword: nil))
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertTrue(store.deleted.isEmpty)
  }

  func testUnchangedPasswordIsNotRewritten() {
    let store = FakePasswordStore()
    let existing = share()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: existing, original: existing, password: "same", loadedPassword: "same"))
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testChangedPasswordIsSaved() {
    let store = FakePasswordStore()
    let existing = share()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: existing, original: existing, password: "new", loadedPassword: "old"))
    XCTAssertEqual(store.saved.map(\.password), ["new"])
  }

  func testRenamedShareKeepsItsAccountAndPassword() {
    let store = FakePasswordStore()
    let original = share()
    let renamed = share(id: original.id, name: "Renamed", server: "other.local")
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: renamed, original: original, password: "pw", loadedPassword: "pw"))
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertTrue(store.deleted.isEmpty)
    XCTAssertEqual(store.relabeled.map(\.account), [original.id.uuidString])
    XCTAssertEqual(store.relabeled.map(\.name), ["Renamed"])
  }

  func testUnchangedNameAndPasswordDoNotRelabel() {
    let store = FakePasswordStore()
    let existing = share()
    let moved = share(id: existing.id, server: "other.local")
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: moved, original: existing, password: "pw", loadedPassword: "pw"))
    XCTAssertTrue(store.relabeled.isEmpty)
  }

  func testRelabelFailureDoesNotBlockSaving() {
    let store = FakePasswordStore()
    store.relabelStatus = errSecInteractionNotAllowed
    let original = share()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: share(id: original.id, name: "Renamed"), original: original, password: "pw",
        loadedPassword: "pw"))
  }

  func testRenamedShareWithNewPasswordIsSavedUnderTheNewName() {
    let store = FakePasswordStore()
    let original = share()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: share(id: original.id, name: "Renamed"), original: original, password: "new",
        loadedPassword: "old"))
    XCTAssertEqual(store.saved.map(\.name), ["Renamed"])
    XCTAssertTrue(store.relabeled.isEmpty)
  }

  func testPasswordWithoutUsernameIsNotSaved() {
    let store = FakePasswordStore()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: share(username: ""), original: nil, password: "secret", loadedPassword: nil))
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertTrue(store.deleted.isEmpty)
  }

  func testClearingTheUsernameDeletesTheUnusedPassword() {
    let store = FakePasswordStore()
    let original = share()
    let guest = share(id: original.id, username: "")
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: guest, original: original, password: "pw", loadedPassword: "pw"))
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(store.deleted, [original.id.uuidString])
  }

  func testClearingTheFieldDeletesTheSavedPassword() {
    let store = FakePasswordStore()
    let existing = share()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: existing, original: existing, password: "", loadedPassword: "old"))
    XCTAssertEqual(store.deleted, [existing.id.uuidString])
  }

  func testEmptyFieldAfterUnreadablePasswordDoesNotDelete() {
    let store = FakePasswordStore()
    let existing = share()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: existing, original: existing, password: "", loadedPassword: nil))
    XCTAssertTrue(store.deleted.isEmpty)
  }

  func testSwitchingToNFSDeletesTheOrphanedPassword() {
    let store = FakePasswordStore()
    let original = share()
    let nfs = share(id: original.id, proto: .nfs)
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: nfs, original: original, password: "pw", loadedPassword: "pw"))
    XCTAssertEqual(store.deleted, [original.id.uuidString])
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testNewNFSShareTouchesNothing() {
    let store = FakePasswordStore()
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: share(proto: .nfs), original: nil, password: "", loadedPassword: nil))
    XCTAssertTrue(store.deleted.isEmpty)
  }

  func testSaveFailureReturnsAnErrorMessage() {
    let store = FakePasswordStore()
    store.saveStatus = errSecAuthFailed
    let error = NetworkSharePasswordSync(store: store).sync(
      share: share(), original: nil, password: "pw", loadedPassword: nil)
    XCTAssertNotNil(error)
    XCTAssertTrue(error?.contains("\(errSecAuthFailed)") ?? false)
  }

  func testDeleteFailureReturnsAnErrorMessageButNotFoundIsFine() {
    let store = FakePasswordStore()
    let existing = share()
    store.deleteStatus = errSecItemNotFound
    XCTAssertNil(
      NetworkSharePasswordSync(store: store).sync(
        share: existing, original: existing, password: "", loadedPassword: "old"))
    store.deleteStatus = errSecInteractionNotAllowed
    let error = NetworkSharePasswordSync(store: store).sync(
      share: existing, original: existing, password: "", loadedPassword: "old")
    XCTAssertTrue(error?.contains("\(errSecInteractionNotAllowed)") ?? false)
  }
}
