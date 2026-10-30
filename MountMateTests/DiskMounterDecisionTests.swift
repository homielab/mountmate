//  Created by homielab.com

import XCTest

@testable import MountMate

final class DiskMounterDecisionTests: XCTestCase {
  private let volumeUUID = "11111111-2222-3333-4444-555555555555"
  private let diskUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

  /// Records which lazy facts the decision read, in order.
  private final class Calls {
    var names: [String] = []
  }

  private struct Case {
    var isDiskImage = false
    var approved = false
    var blockUSB = false
    var proto: String? = "USB"
    var hasVolumeUUID = true
    var hasDiskUUID = true
    var listed = false
    var allowRequested = false
    var automatic = true
    var duplicateUUID = false
  }

  private func decide(_ c: Case, calls: Calls = Calls()) -> MountApprovalDecision {
    let blockedID = "\(diskUUID)-\(volumeUUID)"
    return MountApprovalDecision.decide(
      MountApprovalDecision.Input(
        isDiskImage: c.isDiskImage,
        consumeApproval: {
          calls.names.append("consumeApproval")
          return c.approved
        },
        blockUSBAutoMount: c.blockUSB,
        busProtocol: {
          calls.names.append("busProtocol")
          return c.proto
        },
        volumeUUID: c.hasVolumeUUID ? volumeUUID : nil,
        diskUUID: c.hasDiskUUID ? diskUUID : nil,
        isBlockedVolumeID: { id in
          calls.names.append("isBlockedVolumeID")
          return c.listed && id == blockedID
        },
        isDuplicateUUID: { c.duplicateUUID },
        allowRequestedMounts: c.allowRequested,
        isAutomaticMount: {
          calls.names.append("isAutomaticMount")
          return c.automatic
        }))
  }

  // MARK: - Disk images and MountMate's own mounts

  func testDiskImageIsAllowedWithoutConsumingAnApproval() {
    let calls = Calls()
    let c = Case(isDiskImage: true, approved: true, blockUSB: true, listed: true)
    XCTAssertEqual(decide(c, calls: calls), .allow(.diskImage))
    XCTAssertEqual(calls.names, [])
  }

  func testMountMateApprovalBypassesEveryBlock() {
    let calls = Calls()
    let c = Case(approved: true, blockUSB: true, listed: true)
    XCTAssertEqual(decide(c, calls: calls), .allow(.approvedByMountMate))
    XCTAssertEqual(calls.names, ["consumeApproval"])
  }

  // MARK: - Global USB / SD block

  func testUSBBlockOffNeverReadsTheBusProtocol() {
    let calls = Calls()
    XCTAssertEqual(decide(Case(blockUSB: false), calls: calls), .allow(.notBlocked))
    XCTAssertEqual(calls.names, ["consumeApproval", "isBlockedVolumeID"])
  }

  func testUSBBlockDissentsUSBAndSDDrives() {
    for proto in ["USB", "usb", " SD ", "Secure Digital", "secure digital"] {
      XCTAssertEqual(
        decide(Case(blockUSB: true, proto: proto)), .dissent(blockedByList: false), proto)
    }
  }

  func testUSBOrSDProtocolMatching() {
    for proto in ["USB", "usb", " SD ", "sd", "Secure Digital", "SECURE DIGITAL"] {
      XCTAssertTrue(MountApprovalDecision.isUSBOrSDProtocol(proto), proto)
    }
    for proto in ["SATA", "PCI-Express", "Thunderbolt", "", "USB-C", "SDXC"] {
      XCTAssertFalse(MountApprovalDecision.isUSBOrSDProtocol(proto), proto)
    }
  }

  func testUSBBlockAllowsOtherOrUnknownBuses() {
    for proto in ["SATA", "PCI-Express", "Thunderbolt", "", "USB-C", nil] as [String?] {
      XCTAssertEqual(
        decide(Case(blockUSB: true, proto: proto)), .allow(.notBlocked), String(describing: proto))
    }
  }

  // MARK: - Blocked volumes list

  func testListedVolumeIsDissentedAndFlaggedForTheStartupRule() {
    XCTAssertEqual(decide(Case(listed: true)), .dissent(blockedByList: true))
  }

  func testListedUSBVolumeWithUSBBlockIsFlaggedAsListed() {
    let calls = Calls()
    XCTAssertEqual(
      decide(Case(blockUSB: true, listed: true), calls: calls), .dissent(blockedByList: true))
    XCTAssertEqual(calls.names, ["consumeApproval", "busProtocol", "isBlockedVolumeID"])
  }

  func testVolumeWithoutUUIDIsNeverLookedUpInTheList() {
    let calls = Calls()
    XCTAssertEqual(
      decide(Case(hasVolumeUUID: false, listed: true), calls: calls), .allow(.notBlocked))
    XCTAssertEqual(calls.names, ["consumeApproval"])
    XCTAssertEqual(
      decide(Case(blockUSB: true, hasVolumeUUID: false)), .dissent(blockedByList: false))
  }

  func testBlockedVolumeIDUsesNONEForAMissingDiskUUID() {
    XCTAssertEqual(
      MountApprovalDecision.blockedVolumeID(volumeUUID: volumeUUID, diskUUID: diskUUID),
      "\(diskUUID)-\(volumeUUID)")
    XCTAssertEqual(
      MountApprovalDecision.blockedVolumeID(volumeUUID: volumeUUID, diskUUID: nil),
      "NONE-\(volumeUUID)")
    XCTAssertNil(MountApprovalDecision.blockedVolumeID(volumeUUID: nil, diskUUID: diskUUID))
    // The listed id has the disk UUID, so a volume without one does not match.
    XCTAssertEqual(decide(Case(hasDiskUUID: false, listed: true)), .allow(.notBlocked))
  }

  // MARK: - Volumes sharing a UUID

  func testBlockedCardDoesNotBlockAnotherCardWithTheSameUUID() {
    XCTAssertEqual(decide(Case(listed: true)), .dissent(blockedByList: true))
    XCTAssertEqual(decide(Case(listed: true, duplicateUUID: true)), .allow(.notBlocked))
    XCTAssertNil(
      MountApprovalDecision.blockedVolumeID(
        volumeUUID: volumeUUID, diskUUID: diskUUID, isDuplicateUUID: true))
  }

  func testDiskMounterAndVolumeListBuildTheSameID() {
    func volume(_ id: String, _ device: String, duplicate: Bool = false) -> Volume {
      var v = Volume(
        id: id, deviceIdentifier: device, diskUUID: diskUUID, name: "SD", isMounted: false,
        mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil, usedBytes: nil,
        fileSystemType: "ExFAT", usagePercentage: nil, category: .user, isProtected: false,
        snapshots: [])
      v.isDuplicateUUID = duplicate
      return v
    }
    let single = volume(volumeUUID, "disk4s1")
    XCTAssertEqual(
      single.compositeId,
      MountApprovalDecision.blockedVolumeID(volumeUUID: volumeUUID, diskUUID: diskUUID))
    XCTAssertEqual(single.compositeId, "\(diskUUID)-\(volumeUUID)", "saved ids still match")

    func disk(_ id: String, _ volume: Volume) -> PhysicalDisk {
      PhysicalDisk(
        id: id, diskUUID: nil, connectionType: "SD", name: "Card", totalSize: nil,
        freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: .physical, isRAIDSet: false,
        partitions: [volume], containers: [], storageError: nil)
    }
    let disks = [disk("disk4", single), disk("disk5", volume(volumeUUID, "disk5s1"))]
    let listed = DiskListParser.disambiguatingDuplicateUUIDs(disks).flatMap(\.allVolumes)
    XCTAssertTrue(listed.allSatisfy { $0.isDuplicateUUID && $0.compositeId == nil })

    // The second card appears while only the first is listed.
    XCTAssertTrue(Volume.isUUID(volumeUUID, sharedByOtherThan: "disk5s1", in: [single]))
    XCTAssertTrue(Volume.isUUID(volumeUUID.lowercased(), sharedByOtherThan: "disk5s1", in: listed))
    XCTAssertFalse(Volume.isUUID(volumeUUID, sharedByOtherThan: "disk4s1", in: [single]))
  }

  // MARK: - Allow Requested Mounts

  func testAllowRequestedMountsStillDissentsTheAutomaticMount() {
    let calls = Calls()
    let c = Case(listed: true, allowRequested: true, automatic: true)
    XCTAssertEqual(decide(c, calls: calls), .dissent(blockedByList: true))
    XCTAssertEqual(calls.names, ["consumeApproval", "isBlockedVolumeID", "isAutomaticMount"])
    XCTAssertEqual(
      decide(Case(blockUSB: true, allowRequested: true, automatic: true)),
      .dissent(blockedByList: false))
  }

  func testAllowRequestedMountsAllowsALaterRequestedMount() {
    XCTAssertEqual(
      decide(Case(listed: true, allowRequested: true, automatic: false)),
      .allow(.requestedMount))
    XCTAssertEqual(
      decide(Case(blockUSB: true, allowRequested: true, automatic: false)),
      .allow(.requestedMount))
  }

  func testAutomaticMountIsOnlyCheckedForABlockedVolume() {
    let calls = Calls()
    XCTAssertEqual(
      decide(Case(allowRequested: true, automatic: false), calls: calls), .allow(.notBlocked))
    XCTAssertFalse(calls.names.contains("isAutomaticMount"))
  }

  func testAllowRequestedMountsOffIgnoresHowTheMountStarted() {
    let calls = Calls()
    XCTAssertEqual(
      decide(Case(listed: true, allowRequested: false, automatic: false), calls: calls),
      .dissent(blockedByList: true))
    XCTAssertFalse(calls.names.contains("isAutomaticMount"))
  }

  /// Every combination of the flags against the rules spelled out.
  func testEveryCombination() {
    let bools = [false, true]
    for isDiskImage in bools {
      for approved in bools {
        for blockUSB in bools {
          for usb in bools {
            for listed in bools {
              for allowRequested in bools {
                for automatic in bools {
                  let c = Case(
                    isDiskImage: isDiskImage, approved: approved, blockUSB: blockUSB,
                    proto: usb ? "USB" : "SATA", listed: listed,
                    allowRequested: allowRequested, automatic: automatic)
                  let expected: MountApprovalDecision
                  if isDiskImage {
                    expected = .allow(.diskImage)
                  } else if approved {
                    expected = .allow(.approvedByMountMate)
                  } else if !(blockUSB && usb) && !listed {
                    expected = .allow(.notBlocked)
                  } else if allowRequested && !automatic {
                    expected = .allow(.requestedMount)
                  } else {
                    expected = .dissent(blockedByList: listed)
                  }
                  XCTAssertEqual(decide(c), expected, "\(c)")
                }
              }
            }
          }
        }
      }
    }
  }
}
