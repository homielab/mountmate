import XCTest

@testable import MountMate

final class TimeMachineBackupRulesTests: XCTestCase {
  private let running = """
    Backup session status:
    {
        BackupPhase = Copying;
        ClientID = "com.apple.backupd";
        DestinationMountPoint = "/Volumes/TM Disk";
        Percent = "0.25";
        Running = 1;
    }
    """

  private func volume(_ id: String, mountPoint: String?, timeMachine: Bool) -> Volume {
    var volume = Volume(
      id: id, deviceIdentifier: id, diskUUID: nil, name: id,
      isMounted: mountPoint != nil, mountPoint: mountPoint, freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: nil, fileSystemType: nil, usagePercentage: nil,
      category: .user, isProtected: false, snapshots: [], storageError: nil)
    volume.isTimeMachine = timeMachine
    return volume
  }

  func testParsesRunningBackupAndDestination() {
    XCTAssertEqual(
      TimeMachineBackupRules.status(fromTmutilStatus: running),
      .init(isRunning: true, destinationMountPoint: "/Volumes/TM Disk"))
  }

  func testIdleStatusIsNotRunning() {
    let idle =
      "Backup session status:\n{\n    ClientID = \"com.apple.backupd\";\n    Running = 0;\n}"
    XCTAssertFalse(TimeMachineBackupRules.status(fromTmutilStatus: idle).isRunning)
    XCTAssertFalse(TimeMachineBackupRules.status(fromTmutilStatus: "").isRunning)
  }

  func testOnlyTheDestinationBeingWrittenAsks() {
    let tm = volume("disk4s1", mountPoint: "/Volumes/TM Disk", timeMachine: true)
    let otherTM = volume("disk5s1", mountPoint: "/Volumes/Old TM", timeMachine: true)
    let data = volume("disk6s1", mountPoint: "/Volumes/Data", timeMachine: false)
    let status = TimeMachineBackupRules.status(fromTmutilStatus: running)
    XCTAssertEqual(
      TimeMachineBackupRules.volumesBeingBackedUp([tm, otherTM, data], status: status).map(\.id),
      ["disk4s1"])
  }

  func testUnnamedDestinationCountsEveryTimeMachineVolume() {
    let tm = volume("disk4s1", mountPoint: "/Volumes/TM", timeMachine: true)
    let data = volume("disk6s1", mountPoint: "/Volumes/Data", timeMachine: false)
    XCTAssertEqual(
      TimeMachineBackupRules.volumesBeingBackedUp(
        [tm, data], status: .init(isRunning: true, destinationMountPoint: nil)
      ).map(\.id), ["disk4s1"])
    XCTAssertTrue(
      TimeMachineBackupRules.volumesBeingBackedUp(
        [tm], status: .init(isRunning: false, destinationMountPoint: nil)
      ).isEmpty)
  }
}
