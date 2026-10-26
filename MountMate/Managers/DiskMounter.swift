//  Created by homielab.com

import Combine
import DiskArbitration
import Foundation
import IOKit

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

  private var session: DASession?
  /// Manual mount approvals and disk appearances, guarded by `ledgerLock`
  /// (the Disk Arbitration callbacks run on another queue).
  private var ledger = MountApprovalLedger()
  private let ledgerLock = NSLock()
  private var cancellables = Set<AnyCancellable>()
  /// Guards the launch-time cleanup so it runs once per app launch even when
  /// the session is restarted.
  private var hasPerformedStartupMaintenance = false
  /// When this object was created, i.e. app launch.
  private let createdAt = Date()
  /// The startup sweep only runs for a session started this soon after
  /// launch. A session started later (the user blocks their first volume or
  /// turns on the USB block mid-session) must not sweep, or it would unmount
  /// volumes the user just chose to block.
  private static let startupSweepWindow: TimeInterval = 30

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
    let lifetime = MountApprovalLedger.approvalLifetime
    let expiration = withLedger { $0.approve(identifier) }

    DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
      self?.withLedger { $0.withdrawApproval(for: identifier, ifExpiring: expiration) }
    }
  }

  @objc private func handleDidFinishMount(notification: Notification) {
    guard let identifier = notification.userInfo?["deviceIdentifier"] as? String,
      !identifier.isEmpty
    else { return }
    withLedger { $0.withdrawApproval(for: identifier) }
  }

  private func withLedger<T>(_ body: (inout MountApprovalLedger) -> T) -> T {
    ledgerLock.lock()
    defer { ledgerLock.unlock() }
    return body(&ledger)
  }

  private func startDiskArbitration() {
    guard session == nil else { return }
    Log.mounter.info("Starting Disk Arbitration session")
    session = DASessionCreate(kCFAllocatorDefault)
    guard let session = session else { return }

    let context = Unmanaged.passUnretained(self).toOpaque()

    let mountCallback: DADiskMountApprovalCallback = { (disk, context) -> Unmanaged<DADissenter>? in
      guard let context = context else { return nil }
      let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()
      let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) })

      guard let desc = DADiskCopyDescription(disk) else { return nil }
      guard let description = desc as? [String: Any] else {
        // An unexpected description type must never block the mount.
        Log.mounter.error(
          "Unexpected Disk Arbitration description; approving mount of \(bsdName ?? "unknown volume", privacy: .public)."
        )
        return nil
      }

      // Approve non-physical media (disk images).
      if DiskMounter.isDiskImage(description) {
        return nil
      }

      let volumeUUIDString = DiskMounter.uuidString(
        description[kDADiskDescriptionVolumeUUIDKey as String])
      let diskUUIDString = DiskMounter.uuidString(
        description[kDADiskDescriptionMediaUUIDKey as String])

      // Only mount requests explicitly initiated by MountMate bypass the
      // runtime block. Disk Arbitration does not identify the source of a
      // request from Finder, Terminal, or the OS.
      if this.withLedger({
        $0.consumeApproval(
          bsdName: bsdName, volumeUUID: volumeUUIDString, diskUUID: diskUUIDString)
      }) {
        return nil
      }

      var shouldBlock = false
      // True when the per-volume blocked list (not the global USB/SD block)
      // decided shouldBlock, so a missing startup rule can be added for it.
      var blockedByList = false

      // Global USB block. The feature is named "Block USB Auto-Mount", so
      // it is scoped to USB drives and SD cards.
      if this.blockUSBAutoMount,
        let proto = DiskMounter.busProtocol(of: disk, description: description),
        DiskMounter.isUSBOrSDProtocol(proto)
      {
        shouldBlock = true
      }

      if let volUUID = volumeUUIDString {
        let dUUID = diskUUIDString ?? "NONE"
        let compositeId = "\(dUUID)-\(volUUID)"
        if PersistenceManager.shared.blockedVolumes.contains(where: { $0.id == compositeId }) {
          shouldBlock = true
          blockedByList = true
        }
      }

      if shouldBlock && this.allowRequestedMounts
        && !this.withLedger({ $0.isAutomaticMount(bsdName: bsdName) })
      {
        Log.mounter.notice(
          "Allowing requested mount of blocked volume \(bsdName ?? "unknown volume", privacy: .public)."
        )
        return nil
      }

      if shouldBlock {
        if blockedByList {
          // The volume is connected but macOS still tried to auto-mount it,
          // so it has no startup rule yet. Add one (when "Block at Startup"
          // is on) so the next boot never gets this far.
          PersistenceManager.shared.scheduleStartupBlockReconcile()
        }
        Log.mounter.notice(
          "Dissenting auto-mount for \(bsdName ?? "unknown volume", privacy: .public).")
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil)
        return Unmanaged.passRetained(dissenter)
      }

      // Approved.
      return nil
    }

    let appearedCallback: DADiskAppearedCallback = { disk, context in
      guard let context = context else { return }
      let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()
      let name = DADiskGetBSDName(disk).map { String(cString: $0) }
      this.withLedger { $0.recordAppearance(of: name) }
      NotificationCenter.default.post(name: .diskAppearanceDidChange, object: nil)
    }
    let disappearedCallback: DADiskDisappearedCallback = { disk, context in
      guard let context = context else { return }
      let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()
      let name = DADiskGetBSDName(disk).map { String(cString: $0) }
      this.withLedger { $0.forgetAppearance(of: name) }
      NotificationCenter.default.post(name: .diskAppearanceDidChange, object: nil)
    }

    let matching: [String: Any] = [kDADiskDescriptionVolumeMountableKey as String: kCFBooleanTrue!]
    DARegisterDiskAppearedCallback(session, matching as CFDictionary, appearedCallback, context)
    DARegisterDiskDisappearedCallback(
      session, matching as CFDictionary, disappearedCallback, context)
    DARegisterDiskMountApprovalCallback(session, matching as CFDictionary, mountCallback, context)
    DASessionSetDispatchQueue(session, DispatchQueue.main)

    scheduleStartupMaintenance()
  }

  /// True when the description says the media is a disk image ("Disk Image"
  /// model), which is never blocked. Missing or mistyped keys count as a
  /// physical disk.
  static func isDiskImage(_ description: [String: Any]) -> Bool {
    guard let model = description[kDADiskDescriptionDeviceModelKey as String] as? String else {
      return false
    }
    return model == "Disk Image"
  }

  /// String form of a Disk Arbitration UUID field (a CFUUID), or nil when the
  /// value is missing or not the expected CF type.
  static func uuidString(_ value: Any?) -> String? {
    guard let cfValue = value as CFTypeRef?, CFGetTypeID(cfValue) == CFUUIDGetTypeID() else {
      return nil
    }
    return CFUUIDCreateString(nil, unsafeBitCast(cfValue, to: CFUUID.self)) as String
  }

  /// Bus protocol of the physical device behind `disk` (e.g. "USB", "SD",
  /// "Secure Digital", "SATA", "PCI-Express", "Thunderbolt"), or nil when
  /// unknown. Runs inside the mount approval callback, so it only reads Disk
  /// Arbitration descriptions and the in-kernel IORegistry (microseconds);
  /// it never spawns diskutil.
  fileprivate static func busProtocol(of disk: DADisk, description: [String: Any]) -> String? {
    let protocolKey = kDADiskDescriptionDeviceProtocolKey as String
    // 1. The volume's own description ("BusProtocol" kept for older systems).
    if let proto = description[protocolKey] as? String ?? description["BusProtocol"] as? String {
      return proto
    }
    // 2. The whole disk's description.
    if let wholeDisk = DADiskCopyWholeDisk(disk),
      let wholeDescription = DADiskCopyDescription(wholeDisk) as? [String: Any],
      let proto = wholeDescription[protocolKey] as? String
        ?? wholeDescription["BusProtocol"] as? String
    {
      return proto
    }
    // 3. APFS volumes live on a synthesized container disk whose
    //    descriptions carry no bus information. Walk up the IORegistry from
    //    the volume's media, through the APFS container and its physical
    //    store, to the storage device and read its "Protocol
    //    Characteristics" (where DADeviceProtocol comes from).
    let media = DADiskCopyIOMedia(disk)
    guard media != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(media) }
    guard
      let characteristics = IORegistryEntrySearchCFProperty(
        media, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        as? [String: Any]
    else { return nil }
    return characteristics["Physical Interconnect"] as? String
  }

  /// "USB", "SD" or "Secure Digital", ignoring case.
  fileprivate static func isUSBOrSDProtocol(_ proto: String) -> Bool {
    let value = proto.trimmingCharacters(in: .whitespaces)
    return ["USB", "SD", "Secure Digital"].contains {
      value.caseInsensitiveCompare($0) == .orderedSame
    }
  }

  /// Runs once per app launch, shortly after the Disk Arbitration session
  /// starts: unmounts blocked volumes the OS mounted before MountMate was
  /// running. Mount approval callbacks cannot run before a user-session app
  /// launches, so this is best-effort cleanup for volumes mounted at login.
  /// Skipped for sessions started later than `startupSweepWindow`.
  private func scheduleStartupMaintenance() {
    guard !hasPerformedStartupMaintenance else { return }
    guard Date().timeIntervalSince(createdAt) < Self.startupSweepWindow else {
      hasPerformedStartupMaintenance = true
      return
    }
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
            Log.mounter.notice(
              "Unmounted blocked volume “\(info.name, privacy: .private)” after startup.")
            break
          }
          if Self.isAlreadyUnmounted(result) {
            Log.mounter.info(
              "Blocked volume “\(info.name, privacy: .private)” was already unmounted.")
            break
          }
          Log.mounter.error(
            "Could not unmount blocked volume “\(info.name, privacy: .private)” (attempt \(attempt, privacy: .public)/3): \(result.stderr, privacy: .private)"
          )
          if attempt < 3 {
            Thread.sleep(forTimeInterval: 3.0)
          } else {
            DispatchQueue.main.async {
              NotificationManager.shared.blockedVolumeStillMounted(
                name: info.name, volumeUUID: volumeUUID)
            }
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
    withLedger { $0.removeAll() }
    self.session = nil
  }
}
