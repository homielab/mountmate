import XCTest

@testable import MountMate

final class WholeDiskInfoCacheTests: XCTestCase {
  /// Fake `diskutil info`: counts calls and answers from `answers`.
  private final class FakeDiskutil {
    private let lock = NSLock()
    private var _calls: [String] = []
    var answers: [String: [String: Any]] = [:]

    var calls: [String] { lock.withLock { _calls.sorted() } }
    func reset() { lock.withLock { _calls = [] } }

    func info(for identifier: String) -> [String: Any]? {
      lock.withLock {
        _calls.append(identifier)
        return answers[identifier]
      }
    }
  }

  private var diskutil: FakeDiskutil!
  private var clock: Date!
  private var cache: WholeDiskInfoCache!

  override func setUp() {
    super.setUp()
    diskutil = FakeDiskutil()
    diskutil.answers = [
      "disk0": ["DeviceIdentifier": "disk0", "Internal": true],
      "disk4": ["DeviceIdentifier": "disk4", "Internal": false, "BusProtocol": "USB"],
      "disk5": ["DeviceIdentifier": "disk5", "Internal": false, "BusProtocol": "USB"],
    ]
    clock = Date(timeIntervalSince1970: 1_000)
    cache = WholeDiskInfoCache(
      ttl: 30, now: { [unowned self] in self.clock },
      fetch: { [unowned self] identifier in self.diskutil.info(for: identifier) })
  }

  private func lookup(_ disks: [WholeDiskInfoCache.Disk]) -> WholeDiskInfoCache.Lookup {
    let done = expectation(description: "lookup")
    var result: WholeDiskInfoCache.Lookup?
    cache.lookup(disks) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return result!
  }

  private let disk0 = WholeDiskInfoCache.Disk(identifier: "disk0", identity: "500|GUID|a")
  private let disk4 = WholeDiskInfoCache.Disk(identifier: "disk4", identity: "64|GUID|b")
  private let disk5 = WholeDiskInfoCache.Disk(identifier: "disk5", identity: "32|FDisk|c")

  func testFirstLookupFetchesEveryDisk() {
    let result = lookup([disk0, disk4])

    XCTAssertEqual(diskutil.calls, ["disk0", "disk4"])
    XCTAssertEqual(result.fetched, ["disk0", "disk4"])
    XCTAssertEqual(result.info["disk4"]?["BusProtocol"] as? String, "USB")
    XCTAssertTrue(result.unclassified.isEmpty)
  }

  func testSameTopologyWithinTTLRunsNoDiskutil() {
    _ = lookup([disk0, disk4])
    diskutil.reset()
    clock += 29

    let result = lookup([disk0, disk4])

    XCTAssertEqual(diskutil.calls, [])
    XCTAssertEqual(result.reused, ["disk0", "disk4"])
    XCTAssertEqual(result.info["disk0"]?["Internal"] as? Bool, true)
  }

  func testOnlyNewDiskIsFetched() {
    _ = lookup([disk0, disk4])
    diskutil.reset()

    let result = lookup([disk0, disk4, disk5])

    XCTAssertEqual(diskutil.calls, ["disk5"])
    XCTAssertEqual(result.reused, ["disk0", "disk4"])
    XCTAssertEqual(result.info["disk5"]?["BusProtocol"] as? String, "USB")
  }

  func testOnlyChangedDiskIsFetched() {
    _ = lookup([disk0, disk4])
    diskutil.reset()
    let reformatted = WholeDiskInfoCache.Disk(identifier: "disk4", identity: "64|FDisk|z")

    _ = lookup([disk0, reformatted])

    XCTAssertEqual(diskutil.calls, ["disk4"])
  }

  func testExpiredEntryIsFetchedAgain() {
    _ = lookup([disk0, disk4])
    diskutil.reset()
    clock += 30

    _ = lookup([disk0, disk4])

    XCTAssertEqual(diskutil.calls, ["disk0", "disk4"])
  }

  func testFailedFetchFallsBackToCachedInfoAndRetriesNextTime() {
    _ = lookup([disk0, disk4])
    clock += 60
    diskutil.answers["disk4"] = nil
    diskutil.reset()

    let result = lookup([disk0, disk4])

    XCTAssertEqual(result.info["disk4"]?["BusProtocol"] as? String, "USB")
    XCTAssertTrue(result.unclassified.isEmpty)

    // The stale entry is not refreshed by a failure, so it is tried again.
    diskutil.reset()
    _ = lookup([disk0, disk4])
    XCTAssertEqual(diskutil.calls, ["disk4"])
  }

  func testFailedFetchWithoutMatchingCacheIsUnclassified() {
    _ = lookup([disk4])
    diskutil.answers["disk4"] = nil
    let otherDisk = WholeDiskInfoCache.Disk(identifier: "disk4", identity: "128|GUID|x")

    let result = lookup([otherDisk])

    XCTAssertNil(result.info["disk4"])
    XCTAssertEqual(result.unclassified, ["disk4"])
  }

  func testRemovedDiskIsForgotten() {
    _ = lookup([disk0, disk4])
    _ = lookup([disk0])
    diskutil.reset()

    // Same BSD name and identity reappearing still gets a fresh fetch.
    _ = lookup([disk0, disk4])

    XCTAssertEqual(diskutil.calls, ["disk4"])
  }

  func testListIdentityIgnoresVolumeNamesButNotLayout() {
    let disk: [String: Any] = [
      "DeviceIdentifier": "disk4", "Size": Int64(64_000), "Content": "GUID_partition_scheme",
      "Partitions": [["Content": "Apple_HFS", "Size": Int64(63_000), "VolumeName": "A"]],
    ]
    var renamed = disk
    renamed["Partitions"] = [
      ["Content": "Apple_HFS", "Size": Int64(63_000), "VolumeName": "B"]
    ]
    var repartitioned = disk
    repartitioned["Partitions"] = [
      ["Content": "Microsoft Basic Data", "Size": Int64(63_000)]
    ]

    XCTAssertEqual(
      WholeDiskInfoCache.listIdentity(of: disk), WholeDiskInfoCache.listIdentity(of: renamed))
    XCTAssertNotEqual(
      WholeDiskInfoCache.listIdentity(of: disk), WholeDiskInfoCache.listIdentity(of: repartitioned))
  }
}
