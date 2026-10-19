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

  /// When on, blocking applies only to the automatic mount macOS performs
  /// right after a disk appears. Mounts requested later by other apps
  /// (e.g. a backup tool such as Carbon Copy Cloner, Finder, Disk Utility)
  /// are allowed.
  @Published var allowRequestedMounts: Bool = UserDefaults.standard.bool(
    forKey: "allowRequestedMounts")
  {
    didSet { UserDefaults.standard.set(allowRequestedMounts, forKey: "allowRequestedMounts") }
  }

  /// How long after a disk appears a mount is treated as macOS's automatic
  /// mount rather than a request from an app.
  private static let autoMountWindow: TimeInterval = 15

  private var session: DASession?
  /// When each mountable volume (by BSD name) was last seen appearing.
  private var diskAppearances: [String: Date] = [:]
  private let diskAppearancesLock = NSLock()
  private var manualMountApprovals: [String: Date] = [:]
  private let manualMountApprovalLock = NSLock()
  private var cancellables = Set<AnyCancellable>()
  /// Guards the launch-time cleanup so it runs once per app launch even when
  /// the session is restarted.
  private var hasPerformedStartupMaintenance = false

  init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleWillMount), name: .willManuallyMount, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDidFinishMount), name: .didFinishManualMount, object: nil)

    PersistenceManager.shared.$blockedVolumes
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateSessionState() }
      .store(in: &cancellables)

    updateSessionState()

    // Independent of the Disk Arbitration session, which is off when nothing
    // is blocked but a leftover startup rule may still need removing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
      PersistenceManager.shared.reconcileStartupBlockRulesAtLaunch()
    }
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
    guard let identifier = notification.userInfo?["deviceIdentifier"] as? String,
      !identifier.isEmpty
    else { return }

    // Disk Arbitration only asks for approval after it has probed the disk,
    // which can take well over 5 seconds while a sleeping hard drive spins
    // up. A shorter window made MountMate dissent its own mount of blocked
    // volumes on slow disks ("Volume on diskXsY failed to mount"). The
    // approval is still single-use and is withdrawn as soon as the mount
    // finishes (didFinishManualMount); this is only an upper bound.
    let key = identifier.lowercased()
    let lifetime = Self.manualMountApprovalLifetime
    let expiration = Date().addingTimeInterval(lifetime)
    manualMountApprovalLock.lock()
    manualMountApprovals[key] = expiration
    manualMountApprovalLock.unlock()

    DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
      guard let self else { return }
      self.manualMountApprovalLock.lock()
      if self.manualMountApprovals[key] == expiration {
        self.manualMountApprovals.removeValue(forKey: key)
      }
      self.manualMountApprovalLock.unlock()
    }
  }

  private static let manualMountApprovalLifetime: TimeInterval = 60

  @objc private func handleDidFinishMount(notification: Notification) {
    guard let identifier = notification.userInfo?["deviceIdentifier"] as? String,
      !identifier.isEmpty
    else { return }
    manualMountApprovalLock.lock()
    manualMountApprovals.removeValue(forKey: identifier.lowercased())
    manualMountApprovalLock.unlock()
  }

  private func consumeManualMountApproval(
    bsdName: String?, volumeUUID: String?, diskUUID: String?
  ) -> Bool {
    let identifiers = [bsdName, volumeUUID, diskUUID]
      .compactMap { $0?.lowercased() }
    guard !identifiers.isEmpty else { return false }

    let now = Date()
    manualMountApprovalLock.lock()
    defer { manualMountApprovalLock.unlock() }
    manualMountApprovals = manualMountApprovals.filter { $0.value > now }

    for identifier in identifiers {
      if manualMountApprovals.removeValue(forKey: identifier) != nil {
        return true
      }
    }
    return false
  }

  private func recordAppearance(of bsdName: String?) {
    guard let key = bsdName?.lowercased() else { return }
    diskAppearancesLock.lock()
    diskAppearances[key] = Date()
    diskAppearancesLock.unlock()
  }

  private func forgetAppearance(of bsdName: String?) {
    guard let key = bsdName?.lowercased() else { return }
    diskAppearancesLock.lock()
    diskAppearances.removeValue(forKey: key)
    diskAppearancesLock.unlock()
  }

  /// True when this mount looks like macOS auto-mounting a disk that just
  /// appeared. A disk with no recorded appearance is treated as new (and
  /// recorded now), so callback ordering can never let an auto-mount through.
  private func isAutomaticMount(bsdName: String?) -> Bool {
    guard let key = bsdName?.lowercased() else { return true }
    let now = Date()
    diskAppearancesLock.lock()
    defer { diskAppearancesLock.unlock() }
    guard let appeared = diskAppearances[key] else {
      diskAppearances[key] = now
      return true
    }
    return now.timeIntervalSince(appeared) < Self.autoMountWindow
  }

  private func startDiskArbitration() {
    guard session == nil else { return }
    print("✅ Starting Disk Arbitration session...")
    session = DASessionCreate(kCFAllocatorDefault)
    guard let session = session else { return }

    let context = Unmanaged.passUnretained(self).toOpaque()

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

      // Only mount requests explicitly initiated by MountMate bypass the
      // runtime block. Disk Arbitration does not identify the source of a
      // request from Finder, Terminal, or the OS.
      if this.consumeManualMountApproval(
        bsdName: bsdName, volumeUUID: volumeUUIDString, diskUUID: diskUUIDString)
      {
        return nil
      }

      var shouldBlock = false
      // True when the per-volume blocked list (not the global USB/SD block)
      // decided shouldBlock, so a missing startup rule can be added for it.
      var blockedByList = false

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
          blockedByList = true
        }
      }

      if shouldBlock && this.allowRequestedMounts && !this.isAutomaticMount(bsdName: bsdName) {
        print("✅ Allowing requested mount of blocked volume \(bsdName ?? "unknown volume").")
        return nil
      }

      if shouldBlock {
        if blockedByList {
          // The volume is connected but macOS still tried to auto-mount it,
          // so it has no startup rule yet. Add one (when "Block at Startup"
          // is on) so the next boot never gets this far.
          PersistenceManager.shared.scheduleStartupBlockReconcile()
        }
        print("🚫 Dissenting auto-mount for \(bsdName ?? "unknown volume").")
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil)
        return Unmanaged.passRetained(dissenter)
      }

      // Approved.
      return nil
    }

    let appearedCallback: DADiskAppearedCallback = { disk, context in
      guard let context = context else { return }
      let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()
      this.recordAppearance(of: DADiskGetBSDName(disk).map { String(cString: $0) })
    }
    let disappearedCallback: DADiskDisappearedCallback = { disk, context in
      guard let context = context else { return }
      let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()
      this.forgetAppearance(of: DADiskGetBSDName(disk).map { String(cString: $0) })
    }

    let matching: [String: Any] = [kDADiskDescriptionVolumeMountableKey as String: kCFBooleanTrue!]
    DARegisterDiskAppearedCallback(session, matching as CFDictionary, appearedCallback, context)
    DARegisterDiskDisappearedCallback(session, matching as CFDictionary, disappearedCallback, context)
    DARegisterDiskMountApprovalCallback(session, matching as CFDictionary, mountCallback, context)
    DASessionSetDispatchQueue(session, DispatchQueue.main)

    scheduleStartupMaintenance()
  }

  /// Runs once per app launch, shortly after the Disk Arbitration session
  /// starts: unmounts blocked volumes the OS mounted before MountMate was
  /// running. Mount approval callbacks cannot run before a user-session app
  /// launches, so this is best-effort cleanup for volumes mounted at login.
  private func scheduleStartupMaintenance() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
      guard let self, self.session != nil, !self.hasPerformedStartupMaintenance else { return }
      self.hasPerformedStartupMaintenance = true

      // Snapshot the main-thread-bound lists before doing the diskutil work
      // on a background queue.
      let blockedInfos = PersistenceManager.shared.blockedVolumes
      self.unmountBlockedVolumes(blockedInfos)
    }
  }

  /// Unmounts blocked volumes that are already mounted — typically because
  /// the OS mounted them before MountMate's user-session callback was active.
  /// A few retries absorb transient busyness (Spotlight indexing right after
  /// login). Never forces: a persistently busy volume is left mounted.
  private func unmountBlockedVolumes(_ blockedInfos: [ManagedVolumeInfo]) {
    DispatchQueue.global(qos: .utility).async {
      for info in blockedInfos {
        guard
          let volumeUUID = PersistenceManager.normalizedSystemVolumeUUID(info.volumeUUID)
        else { continue }

        let infoResult = runProcess(
          executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", volumeUUID])
        guard infoResult.succeeded,
          let data = infoResult.stdout.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
          let device = plist["DeviceIdentifier"] as? String,
          let mountPoint = plist["MountPoint"] as? String
        else { continue }

        let trimmedMountPoint = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMountPoint.isEmpty,
          trimmedMountPoint.caseInsensitiveCompare("Not Mounted") != .orderedSame
        else { continue }

        for attempt in 1...3 {
          let result = runProcess(
            executable: "/usr/sbin/diskutil", arguments: ["unmount", device])
          if result.succeeded {
            print("🚫 Unmounted blocked volume “\(info.name)” after startup.")
            break
          }
          if Self.isAlreadyUnmounted(result) {
            print("ℹ️ Blocked volume “\(info.name)” was already unmounted.")
            break
          }
          print(
            "⚠️ Could not unmount blocked volume “\(info.name)” (attempt \(attempt)/3): \(result.stderr)"
          )
          if attempt < 3 {
            Thread.sleep(forTimeInterval: 3.0)
          }
        }
      }
    }
  }

  private static func isAlreadyUnmounted(_ result: ProcessResult) -> Bool {
    let output = "\(result.stdout)\n\(result.stderr)".lowercased()
    return output.contains("already unmounted") || output.contains("not mounted")
  }

  private func stopDiskArbitration() {
    guard let session = session else { return }
    DASessionSetDispatchQueue(session, nil)
    manualMountApprovalLock.lock()
    manualMountApprovals.removeAll()
    manualMountApprovalLock.unlock()
    diskAppearancesLock.lock()
    diskAppearances.removeAll()
    diskAppearancesLock.unlock()
    self.session = nil
  }
}
