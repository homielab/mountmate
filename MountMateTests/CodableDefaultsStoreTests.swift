//  Created by homielab.com

import XCTest

@testable import MountMate

final class CodableDefaultsStoreTests: XCTestCase {
  private struct Unencodable: Codable {
    func encode(to encoder: Encoder) throws {
      throw EncodingError.invalidValue(
        0, EncodingError.Context(codingPath: [], debugDescription: "test failure"))
    }
    init() {}
    init(from decoder: Decoder) throws {}
  }

  private func makeDefaults() throws -> (UserDefaults, () -> Void) {
    let suite = "CodableStoreTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    return ({ defaults }(), { defaults.removePersistentDomain(forName: suite) })
  }

  func testSaveReportsFailureAndKeepsTheOldValue() throws {
    let (defaults, cleanup) = try makeDefaults()
    defer { cleanup() }
    XCTAssertTrue(CodableDefaultsStore.save(["a"], to: "k", defaults: defaults))
    let before = defaults.data(forKey: "k")
    XCTAssertFalse(CodableDefaultsStore.save([Unencodable()], to: "k", defaults: defaults))
    XCTAssertEqual(defaults.data(forKey: "k"), before)
  }

  func testWakePlanThatCannotBeReadIsDroppedWithoutCrashing() throws {
    let (defaults, cleanup) = try makeDefaults()
    defer { cleanup() }
    defaults.set(Data("not json".utf8), forKey: WakeRemountManager.planKey)
    let manager = WakeRemountManager(defaults: defaults)
    XCTAssertNil(manager.plan)
    XCTAssertNil(defaults.data(forKey: WakeRemountManager.planKey))
  }
}
