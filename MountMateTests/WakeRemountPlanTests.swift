import XCTest

@testable import MountMate

final class WakeRemountPlanTests: XCTestCase {
  private let uuidA = "11111111-1111-1111-1111-111111111111"
  private let uuidB = "22222222-2222-2222-2222-222222222222"

  private func volume(_ uuid: String?, name: String, id: String = "disk9s1") -> Volume {
    Volume(
      id: uuid ?? id, deviceIdentifier: id, diskUUID: nil, name: name, isMounted: true,
      mountPoint: "/Volumes/\(name)", freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  func testRecordsVolumesWithStableUUIDOnly() {
    let plan = WakeRemountPlan(volumes: [
      volume(uuidA, name: "A"), volume(nil, name: "NoUUID"), volume(uuidA, name: "Dup"),
    ])
    XCTAssertEqual(plan.entries.map(\.volumeUUID), [uuidA])
  }

  func testExcludingFailuresAndUserUnmounts() {
    let a = volume(uuidA, name: "A")
    let b = volume(uuidB, name: "B")
    let plan = WakeRemountPlan(volumes: [a, b]).excluding([b])
    XCTAssertEqual(plan.entries.map(\.name), ["A"])
    XCTAssertTrue(plan.excluding([a]).isEmpty)
  }

  func testRemainingDropsMountedEntries() {
    let plan = WakeRemountPlan(volumes: [volume(uuidA, name: "A"), volume(uuidB, name: "B")])
    XCTAssertEqual(plan.remaining(afterMounted: [uuidA]).entries.map(\.volumeUUID), [uuidB])
  }

  func testVolumesToMountSkipsDisconnectedAndMounted() {
    let plan = WakeRemountPlan(volumes: [volume(uuidA, name: "A"), volume(uuidB, name: "B")])
    XCTAssertEqual(
      plan.volumesToMount(presentUUIDs: [uuidA], mountedUUIDs: []).map(\.volumeUUID), [uuidA])
    XCTAssertTrue(
      plan.volumesToMount(presentUUIDs: [uuidA, uuidB], mountedUUIDs: [uuidA, uuidB]).isEmpty)
  }

  func testUnfinishedNamesOnlyAfterTimeout() {
    let plan = WakeRemountPlan(volumes: [volume(uuidA, name: "A"), volume(uuidB, name: "B")])
    XCTAssertTrue(plan.unfinishedNames(stillMounted: [uuidA]).isEmpty)
    XCTAssertEqual(plan.markingSleepTimedOut().unfinishedNames(stillMounted: [uuidA]), ["A"])
  }

  func testPlanSurvivesEncoding() throws {
    let plan = WakeRemountPlan(volumes: [volume(uuidA, name: "A")]).markingSleepTimedOut()
    let data = try JSONEncoder().encode(plan)
    XCTAssertEqual(try JSONDecoder().decode(WakeRemountPlan.self, from: data), plan)
  }

  func testManagerSavesSettlesAndForgets() throws {
    let suite = "WakeRemountTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = WakeRemountManager(defaults: defaults)
    let a = volume(uuidA, name: "A")
    let b = volume(uuidB, name: "B")

    manager.begin(volumes: [a, b])
    manager.settle(failed: [b])
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])
    manager.forget([a])
    XCTAssertNil(manager.plan)

    defaults.set(false, forKey: WakeRemountManager.enabledKey)
    manager.begin(volumes: [a])
    XCTAssertNil(manager.plan)
  }

  func testAddingKeepsEachVolumeOnceAndTheSleepTimeOutMark() {
    let first = WakeRemountPlan(volumes: [volume(uuidA, name: "A")])
    let second = WakeRemountPlan(volumes: [volume(uuidA, name: "A"), volume(uuidB, name: "B")])
      .markingSleepTimedOut()
    let merged = first.adding(second)
    XCTAssertEqual(merged.entries.map(\.volumeUUID), [uuidA, uuidB])
    XCTAssertTrue(merged.sleepTimedOut)
    XCTAssertFalse(first.adding(WakeRemountPlan(volumes: [])).sleepTimedOut)
  }

  private func share(_ name: String) -> NetworkShare {
    NetworkShare(name: name, server: "nas.local", sharePath: name, username: "u")
  }

  func testSharesAreRecordedByIdentityOnce() {
    let a = share("A")
    let plan = WakeRemountPlan(shares: [a, a, share("B")])
    XCTAssertEqual(plan.shares.map(\.shareID).first, a.id)
    XCTAssertEqual(plan.shares.count, 2)
    XCTAssertTrue(plan.entries.isEmpty)
    XCTAssertFalse(plan.isEmpty)
  }

  func testExcludingAndRemainingSharesLeaveVolumesAlone() {
    let a = share("A")
    let b = share("B")
    let plan = WakeRemountPlan(shares: [a, b], volumes: [volume(uuidA, name: "V")])
    XCTAssertEqual(plan.excludingShares([a.id]).shares.map(\.name), ["B"])
    XCTAssertEqual(plan.remainingShares(afterMounted: [b.id]).shares.map(\.name), ["A"])
    XCTAssertEqual(plan.excludingShares([a.id, b.id]).entries.map(\.name), ["V"])
  }

  func testAddingMergesSharesOnce() {
    let a = share("A")
    let b = share("B")
    let merged = WakeRemountPlan(shares: [a]).adding(WakeRemountPlan(shares: [a, b]))
    XCTAssertEqual(merged.shares.map(\.name), ["A", "B"])
  }

  func testPlanSavedBeforeSharesStillDecodes() throws {
    let json = #"{"entries":[{"volumeUUID":"\#(uuidA)","name":"A"}],"sleepTimedOut":false}"#
    let plan = try JSONDecoder().decode(WakeRemountPlan.self, from: Data(json.utf8))
    XCTAssertEqual(plan.entries.map(\.name), ["A"])
    XCTAssertTrue(plan.shares.isEmpty)
  }

  func testSharesSurviveEncoding() throws {
    let plan = WakeRemountPlan(shares: [share("A")])
    let data = try JSONEncoder().encode(plan)
    XCTAssertEqual(try JSONDecoder().decode(WakeRemountPlan.self, from: data), plan)
  }
}
