//  Created by homielab.com

import Foundation

/// Manual unmounts and ejects ask first when Time Machine is backing up to
/// one of the volumes. Automatic unmounts already leave Time Machine alone.
extension DriveManager {
  /// Main thread. Runs `proceed` right away when no mounted Time Machine
  /// volume is involved; otherwise reads `tmutil status` off the main thread
  /// and, when a backup is writing to one of `volumes`, asks first.
  /// - Parameter skip: runs the action without the volumes being backed up.
  func confirmingTimeMachineBackup(
    _ volumes: [Volume], proceedTitle: String,
    proceed: @escaping () -> Void, skip: @escaping ([Volume]) -> Void
  ) {
    guard volumes.contains(where: { $0.isTimeMachine && $0.isMounted }) else {
      proceed()
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let output = runProcess(executable: "/usr/bin/tmutil", arguments: ["status"], timeout: 3)
      let status = TimeMachineBackupRules.status(fromTmutilStatus: output.stdout)
      let busy = TimeMachineBackupRules.volumesBeingBackedUp(volumes, status: status)
      DispatchQueue.main.async {
        guard let first = busy.first else {
          proceed()
          return
        }
        self.userActionError = AppAlert(
          title: String(
            format: NSLocalizedString(
              "Time Machine is backing up to “%@”",
              comment: "Alert title before unmounting or ejecting a volume a backup is writing to"),
            first.name),
          message: NSLocalizedString(
            "Unmounting it now stops the backup. Time Machine tries again at its next backup.",
            comment: "Alert message: Time Machine backup in progress"),
          kind: .timeMachineBackup(
            TimeMachineBackupAppAlert(
              proceedTitle: proceedTitle, onProceed: proceed,
              onSkip: { skip(busy) })))
      }
    }
  }

  static var unmountAnywayTitle: String {
    NSLocalizedString("Unmount Anyway", comment: "Button: unmount during a Time Machine backup")
  }

  static var ejectAnywayTitle: String {
    NSLocalizedString("Eject Anyway", comment: "Button: eject during a Time Machine backup")
  }

  /// "Unmount All" from the menu.
  func unmountAllAskingAboutTimeMachine() {
    let volumes = unmountAllCandidates
    confirmingTimeMachineBackup(
      volumes, proceedTitle: Self.unmountAnywayTitle,
      proceed: { self.unmountAllDrives(volumes: volumes) },
      skip: { busy in
        let ids = Set(busy.map(\.id))
        let rest = volumes.filter { !ids.contains($0.id) }
        if !rest.isEmpty { self.unmountAllDrives(volumes: rest) }
      })
  }

  /// "Eject All External Disks" from the menu.
  func ejectAllAskingAboutTimeMachine() {
    let disks = ejectAllCandidates
    confirmingTimeMachineBackup(
      disks.flatMap(\.allVolumes), proceedTitle: Self.ejectAnywayTitle,
      proceed: { self.ejectAllDisks(disks: disks) },
      skip: { busy in
        let ids = Set(busy.map(\.id))
        let rest = disks.filter { !$0.allVolumes.contains { ids.contains($0.id) } }
        if !rest.isEmpty { self.ejectAllDisks(disks: rest) }
      })
  }

  /// One volume's Unmount button or menu item.
  func unmountAskingAboutTimeMachine(_ volume: Volume) {
    confirmingTimeMachineBackup(
      [volume], proceedTitle: Self.unmountAnywayTitle,
      proceed: { self.unmount(volume: volume) }, skip: { _ in })
  }

  /// One disk's Eject button or menu item.
  func ejectAskingAboutTimeMachine(_ disk: PhysicalDisk) {
    confirmingTimeMachineBackup(
      disk.allVolumes, proceedTitle: Self.ejectAnywayTitle,
      proceed: { self.eject(disk: disk) }, skip: { _ in })
  }
}
