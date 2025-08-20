//  Created by homielab.com

import DiskArbitration
import Foundation

class DiskMounter: ObservableObject {
  @Published var blockUSBAutoMount: Bool = UserDefaults.standard.bool(forKey: "blockUSBAutoMount")
  {
    didSet {
      UserDefaults.standard.set(blockUSBAutoMount, forKey: "blockUSBAutoMount")
      if blockUSBAutoMount {
        startDiskArbitration()
      } else {
        stopDiskArbitration()
      }
    }
  }

  private var session: DASession?
  private var approvingManualMountFor: String?
  private var clearApprovalWorkItem: DispatchWorkItem?

  init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleWillMount), name: .willManuallyMount, object: nil)
    if blockUSBAutoMount {
      startDiskArbitration()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    stopDiskArbitration()
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
    session = DASessionCreate(kCFAllocatorDefault)
    guard let session = session else { return }

    let mountCallback: DADiskMountApprovalCallback = {
      (disk, context) -> Unmanaged<DADissenter>? in
      guard let context = context else { return nil }
      let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()

      if let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) {
        if let approvedDisk = this.approvingManualMountFor, approvedDisk == bsdName {
          return nil
        }
      }

      if let desc = DADiskCopyDescription(disk) {
        let description = desc as! [String: Any]
        let protocolName =
          description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        if protocolName == "USB" {
          let dissenter = DADissenterCreate(
            kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil)
          return Unmanaged.passRetained(dissenter)
        }
      }
      return nil
    }

    let matching: [String: Any] = [
      kDADiskDescriptionVolumeMountableKey as String: kCFBooleanTrue!
    ]
    let context = Unmanaged.passUnretained(self).toOpaque()
    DARegisterDiskMountApprovalCallback(
      session, matching as CFDictionary, mountCallback, context)
    DASessionSetDispatchQueue(session, DispatchQueue.main)
  }

  private func stopDiskArbitration() {
    guard let session = session else { return }
    DASessionSetDispatchQueue(session, nil)
    self.session = nil
  }
}
