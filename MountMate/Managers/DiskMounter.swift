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

      // approve manual mounts.
      if let name = bsdName, let approved = this.approvingManualMountFor, approved == name {
        return nil
      }

      guard let desc = DADiskCopyDescription(disk) else { return nil }
      let description = desc as! [String: Any]

      // approve non-physical media.
      if let model = description[kDADiskDescriptionDeviceModelKey as String] as? String,
        model == "Disk Image"
      {
        return nil
      }

      var shouldBlock = false

      // global USB block.
      if this.blockUSBAutoMount
        && (description[kDADiskDescriptionDeviceProtocolKey as String] as? String) == "USB"
      {
        shouldBlock = true
      }

      // specific volume is in the blocked list.
      if let volumeUUID = description[kDADiskDescriptionVolumeUUIDKey as String] as? String,
        let diskUUID = description[kDADiskDescriptionMediaUUIDKey as String] as? String
      {
        let compositeId = "\(diskUUID)-\(volumeUUID)"
        if PersistenceManager.shared.blockedVolumes.contains(where: { $0.id == compositeId }) {
          shouldBlock = true
        }
      }

      if shouldBlock {
        print("🚫 Dissenting auto-mount for \(bsdName ?? "unknown volume").")
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil)
        return Unmanaged.passRetained(dissenter)
      }

      // approved
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
