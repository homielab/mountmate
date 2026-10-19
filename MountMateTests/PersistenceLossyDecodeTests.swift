//  Created by homielab.com

import XCTest

@testable import MountMate

final class PersistenceLossyDecodeTests: XCTestCase {
  private struct Item: Codable, Equatable {
    let name: String
    let count: Int
  }

  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "PersistenceLossyDecodeTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  // MARK: - decodeLossyArray

  func testDecodesAllValidElements() throws {
    let data = try JSONEncoder().encode([Item(name: "a", count: 1), Item(name: "b", count: 2)])
    let result = PersistenceManager.decodeLossyArray(Item.self, from: data)
    XCTAssertEqual(result.elements, [Item(name: "a", count: 1), Item(name: "b", count: 2)])
    XCTAssertFalse(result.hadFailures)
  }

  func testSkipsUndecodableElementsAndKeepsTheRest() {
    let json = """
      [{"name":"a","count":1},{"name":"broken"},{"name":"c","count":"x"},{"name":"d","count":4}]
      """
    let result = PersistenceManager.decodeLossyArray(Item.self, from: Data(json.utf8))
    XCTAssertEqual(result.elements, [Item(name: "a", count: 1), Item(name: "d", count: 4)])
    XCTAssertTrue(result.hadFailures)
  }

  func testSkipsElementsOfTheWrongJSONType() {
    let json = #"[42, "text", {"name":"a","count":1}]"#
    let result = PersistenceManager.decodeLossyArray(Item.self, from: Data(json.utf8))
    XCTAssertEqual(result.elements, [Item(name: "a", count: 1)])
    XCTAssertTrue(result.hadFailures)
  }

  func testPayloadThatIsNotAnArrayYieldsNothingAndReportsFailure() {
    for json in [#"{"name":"a","count":1}"#, "not json", ""] {
      let result = PersistenceManager.decodeLossyArray(Item.self, from: Data(json.utf8))
      XCTAssertEqual(result.elements, [], json)
      XCTAssertTrue(result.hadFailures, json)
    }
  }

  func testEmptyArrayHasNoFailures() {
    let result = PersistenceManager.decodeLossyArray(Item.self, from: Data("[]".utf8))
    XCTAssertEqual(result.elements, [])
    XCTAssertFalse(result.hadFailures)
  }

  // MARK: - load + backup

  func testLoadKeepsValidElementsAndBacksUpRawDataOnce() {
    let key = "items"
    let raw = Data(#"[{"name":"a","count":1},{"name":"broken"}]"#.utf8)
    defaults.set(raw, forKey: key)

    let loaded: [Item] = PersistenceManager.load(from: key, defaults: defaults)
    XCTAssertEqual(loaded, [Item(name: "a", count: 1)])

    let backupKeys = defaults.dictionaryRepresentation().keys.filter {
      $0.hasPrefix("\(key)_backup_")
    }
    XCTAssertEqual(backupKeys.count, 1)
    XCTAssertEqual(backupKeys.first.flatMap { defaults.data(forKey: $0) }, raw)

    // A second load with the same app version does not add another backup.
    let _: [Item] = PersistenceManager.load(from: key, defaults: defaults)
    XCTAssertEqual(
      defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("\(key)_backup_") }.count, 1)
  }

  func testLoadDoesNotBackUpFullyDecodableData() throws {
    let key = "items"
    defaults.set(try JSONEncoder().encode([Item(name: "a", count: 1)]), forKey: key)

    let loaded: [Item] = PersistenceManager.load(from: key, defaults: defaults)
    XCTAssertEqual(loaded, [Item(name: "a", count: 1)])
    XCTAssertTrue(
      defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("\(key)_backup") }.isEmpty)
  }

  func testLoadOfMissingKeyIsEmpty() {
    let loaded: [Item] = PersistenceManager.load(from: "missing", defaults: defaults)
    XCTAssertEqual(loaded, [])
  }

  func testBackupIsMadeAgainForANewAppVersion() {
    let key = "items"
    let raw = Data("garbage".utf8)
    PersistenceManager.backUpUndecodableData(
      raw, forKey: key, defaults: defaults, appVersion: "1.0 (1)",
      now: Date(timeIntervalSince1970: 100))
    PersistenceManager.backUpUndecodableData(
      raw, forKey: key, defaults: defaults, appVersion: "1.0 (1)",
      now: Date(timeIntervalSince1970: 200))
    PersistenceManager.backUpUndecodableData(
      raw, forKey: key, defaults: defaults, appVersion: "1.1 (2)",
      now: Date(timeIntervalSince1970: 300))

    XCTAssertEqual(defaults.data(forKey: "items_backup_100"), raw)
    XCTAssertNil(defaults.data(forKey: "items_backup_200"))
    XCTAssertEqual(defaults.data(forKey: "items_backup_300"), raw)
  }

  func testUniqueShareNameAppendsCounterOnCollision() {
    XCTAssertEqual(PersistenceManager.uniqueShareName("public", existing: []), "public")
    XCTAssertEqual(
      PersistenceManager.uniqueShareName("public", existing: ["Public"]), "public (2)")
    XCTAssertEqual(
      PersistenceManager.uniqueShareName("public", existing: ["public", "public (2)"]),
      "public (3)")
  }
}
