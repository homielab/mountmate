//  Created by homielab.com

import Security
import XCTest

@testable import MountMate

/// Records calls instead of touching the real Keychain.
private final class RecordingPasswordStore: PasswordStore {
  struct SavedItem: Equatable {
    let account: String
    let name: String
    let kind: KeychainItemKind
  }

  var saved: [SavedItem] = []
  var deleted: [String] = []
  var saveStatus: OSStatus = errSecSuccess

  func save(password: String, for account: String, name: String, kind: KeychainItemKind)
    -> OSStatus
  {
    saved.append(SavedItem(account: account, name: name, kind: kind))
    return saveStatus
  }

  func delete(account: String) -> OSStatus {
    deleted.append(account)
    return errSecSuccess
  }

  func updateLabel(for account: String, name: String, kind: KeychainItemKind) -> OSStatus {
    errSecSuccess
  }
}

final class KeychainPasswordTests: XCTestCase {
  private let volumeUUID = "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"

  private func volume(name: String = "Backup") -> Volume {
    Volume(
      id: volumeUUID, deviceIdentifier: "disk4s1", diskUUID: nil, name: name,
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "apfs", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  // MARK: - Save only after a successful unlock

  func testFailedUnlockSavesNothing() {
    let store = RecordingPasswordStore()
    let status = EncryptedVolumeUnlocker.rememberPassphraseIfUnlocked(
      "typo", for: volume(), unlocked: false, remember: true, store: store)
    XCTAssertNil(status)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testSuccessfulUnlockSavesLabeledItemWhenAsked() {
    let store = RecordingPasswordStore()
    let status = EncryptedVolumeUnlocker.rememberPassphraseIfUnlocked(
      "secret", for: volume(), unlocked: true, remember: true, store: store)
    XCTAssertEqual(status, errSecSuccess)
    XCTAssertEqual(
      store.saved, [.init(account: volumeUUID, name: "Backup", kind: .apfsVolume)])
  }

  func testSuccessfulUnlockWithoutRememberSavesNothing() {
    let store = RecordingPasswordStore()
    let status = EncryptedVolumeUnlocker.rememberPassphraseIfUnlocked(
      "secret", for: volume(), unlocked: true, remember: false, store: store)
    XCTAssertNil(status)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testSaveFailureIsReported() {
    let store = RecordingPasswordStore()
    store.saveStatus = errSecInteractionNotAllowed
    let status = EncryptedVolumeUnlocker.rememberPassphraseIfUnlocked(
      "secret", for: volume(), unlocked: true, remember: true, store: store)
    XCTAssertEqual(status, errSecInteractionNotAllowed)
  }

  // MARK: - Item attributes

  func testLabelNamesTheVolume() {
    XCTAssertEqual(KeychainManager.itemLabel(name: "Backup"), "MountMate – Backup")
    XCTAssertEqual(KeychainManager.itemLabel(name: "  Backup \n"), "MountMate – Backup")
    XCTAssertEqual(KeychainManager.itemLabel(name: "   "), "MountMate")
  }

  func testDisplayAttributesCarryLabelAndKind() {
    let apfs = KeychainManager.displayAttributes(name: "Backup", kind: .apfsVolume)
    XCTAssertEqual(apfs[kSecAttrLabel as String] as? String, "MountMate – Backup")
    XCTAssertEqual(apfs[kSecAttrDescription as String] as? String, "APFS volume")

    let share = KeychainManager.displayAttributes(name: "NAS", kind: .networkShare)
    XCTAssertEqual(share[kSecAttrLabel as String] as? String, "MountMate – NAS")
    XCTAssertEqual(share[kSecAttrDescription as String] as? String, "Network share")
  }

  /// Items saved by older versions have no label or description. Reads,
  /// updates and deletes match on service and account only, so they still
  /// find those items.
  func testLookupQueryStillMatchesUnlabeledItems() {
    let query = KeychainManager.baseQuery(account: volumeUUID)
    XCTAssertEqual(
      Set(query.keys),
      [
        kSecClass as String, kSecAttrService as String, kSecAttrAccount as String,
      ])
    XCTAssertEqual(query[kSecAttrService as String] as? String, "com.homielab.mountmate")
    XCTAssertEqual(query[kSecAttrAccount as String] as? String, volumeUUID)
    XCTAssertNil(query[kSecAttrLabel as String])
    XCTAssertNil(query[kSecAttrDescription as String])
  }
}
