//  Created by homielab.com

import Combine
import DiskArbitration
import Foundation

class DiskMounter: ObservableObject {
  @Published var blockUSBAutoMount: Bool = UserDefaults.standard.bool(forKey: "blockUSBAutoMount")
  {
    didSet {
      UserDefaults.standard.set(blockUSBAutoMount, forKey: "blockUSBAutoMount")
      updateSessionState()
    }
  }

  private var session: DASession?
  private var approvingManualMountFor: String?
  private var clearApprovalWorkItem: DispatchWorkItem?
  private var cancellables = Set<AnyCancellable>()

  init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleWillMount), name: .willManuallyMount, object: nil)

    PersistenceManager.shared.$blockedVolumes
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateSessionState() }
      .store(in: &cancellables)

    updateSessionState()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    stopDiskArbitration()
  }

  private func updateSessionState() {
    let shouldBeActive = blockUSBAutoMount || !PersistenceManager.shared.blockedVolumes.isEmpty
    if shouldBeActive && session == nil {
      startDiskArbitration()
    } else if !shouldBeActive && session != nil {
      stopDiskArbitration()
    }
  }

  @objc private func handleWillMount(notification: Notification) {
    clearApprovalWorkItem?.cancel()
    if let identifier = notification.userInfo?["deviceIdentifier"] as? String {
      self.approvingManualMountFor = identifier
      let workItem = DispatchWorkItem { [weak self] in
        self?.approvingManualMountFor = nil
      }
      self.clearApprovalWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
  }

  private func startDiskArbitration() {
    guard session == nil else { return }
    print("✅ Starting Disk Arbitration session...")
    session = DASessionCreate(kCFAllocatorDefault)
    guard let session = session else { return }

    let mountCallback: DADiskMountApprovalCallback = { (disk, context) -> Unmanaged<DADissenter>? in
      guard let context = context else { return nil }
      let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()
      let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) })

      guard let desc = DADiskCopyDescription(disk) else { return nil }
      let description = desc as! [String: Any]

      // Approve non-physical media (disk images).
      if let model = description[kDADiskDescriptionDeviceModelKey as String] as? String,
        model == "Disk Image"
      {
        return nil
      }

      // Specific volume is in the blocked list.
      let rawVolumeUUID = description[kDADiskDescriptionVolumeUUIDKey as String]
      let rawDiskUUID = description[kDADiskDescriptionMediaUUIDKey as String]

      var volumeUUIDString: String?
      var diskUUIDString: String?

      if let volCF = rawVolumeUUID as CFTypeRef?, CFGetTypeID(volCF) == CFUUIDGetTypeID() {
        volumeUUIDString = CFUUIDCreateString(nil, (volCF as! CFUUID)) as String
      }
      if let diskCF = rawDiskUUID as CFTypeRef?, CFGetTypeID(diskCF) == CFUUIDGetTypeID() {
        diskUUIDString = CFUUIDCreateString(nil, (diskCF as! CFUUID)) as String
      }

      // Approve manual mounts (checking BSD name or Volume UUID / Disk UUID).
      if let approved = this.approvingManualMountFor {
        if approved == "*" {
          return nil
        }
        if let name = bsdName, approved.lowercased() == name.lowercased() {
          return nil
        }
        if let volUUID = volumeUUIDString, approved.lowercased() == volUUID.lowercased() {
          return nil
        }
        if let diskUUID = diskUUIDString, approved.lowercased() == diskUUID.lowercased() {
          return nil
        }
      }

      var shouldBlock = false

      // Global USB block.
      // kDADiskDescriptionDeviceProtocolKey ("DADeviceProtocol") is rarely
      // populated at the volume level. The reliable key is "BusProtocol",
      // which lives in the whole-disk description. Walk up to the whole disk
      // and read its description when the volume-level one lacks bus info.
      if this.blockUSBAutoMount {
        // Try the volume-level description first.
        var busProtocol = description["BusProtocol"] as? String

        // Fall back to the whole-disk (parent) description if not present.
        if busProtocol == nil, let wholeDisk = DADiskCopyWholeDisk(disk) {
          if let parentDesc = DADiskCopyDescription(wholeDisk) {
            let parentDict = parentDesc as! [String: Any]
            busProtocol = parentDict["BusProtocol"] as? String
          }
        }

        // Block USB drives and SD cards. "BusProtocol" values observed on
        // macOS include "USB", "SD", "Bluetooth", "Thunderbolt", etc.
        // The feature is named "Block USB Auto-Mount" so scope to USB/SD.
        if let proto = busProtocol,
          proto.caseInsensitiveCompare("USB") == .orderedSame
            || proto.caseInsensitiveCompare("SD") == .orderedSame
        {
          shouldBlock = true
        }
      }

      if let volUUID = volumeUUIDString {
        let dUUID = diskUUIDString ?? "NONE"
        let compositeId = "\(dUUID)-\(volUUID)"
        if PersistenceManager.shared.blockedVolumes.contains(where: { $0.id == compositeId }) {
          shouldBlock = true
        }
      }

      if shouldBlock {
        print("🚫 Dissenting auto-mount for \(bsdName ?? "unknown volume").")
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil)
        return Unmanaged.passRetained(dissenter)
      }

      // Approved.
      return nil
    }

    let matching: [String: Any] = [kDADiskDescriptionVolumeMountableKey as String: kCFBooleanTrue!]
    let context = Unmanaged.passUnretained(self).toOpaque()
    DARegisterDiskMountApprovalCallback(session, matching as CFDictionary, mountCallback, context)
    DASessionSetDispatchQueue(session, DispatchQueue.main)
  }

  private func stopDiskArbitration() {
    guard let session = session else { return }
    DASessionSetDispatchQueue(session, nil)
    self.session = nil
  }
}
