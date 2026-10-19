//  Created by homielab.com

import SwiftUI

struct DiskAndVolumesView: View {
  let disk: PhysicalDisk
  let listState: VolumeListState
  let customMountPointEditor: CustomMountPointEditorState
  @State private var isExpanded = true
  @AppStorage("showOnlyVolumes") private var showOnlyVolumes = false

  private var visibleContainers: [APFSContainer] {
    disk.containers.filter { !$0.volumes.isEmpty }
  }

  var body: some View {
    Group {
      if !showOnlyVolumes {
        DiskHeaderRow(disk: disk, isExpanded: $isExpanded)
      }
      if isExpanded || showOnlyVolumes {
        ForEach(disk.partitions) { partition in
          VolumeRowView(
            volume: partition,
            context: .disk,
            listState: listState,
            customMountPointEditor: customMountPointEditor
          )
          .padding(.leading, showOnlyVolumes ? 0 : 24)
        }
        ForEach(visibleContainers) { container in
          if !showOnlyVolumes {
            ContainerRowView(container: container)
          }
          ForEach(container.volumes) { volume in
            VolumeRowView(
              volume: volume,
              context: .disk,
              listState: listState,
              customMountPointEditor: customMountPointEditor
            )
            .padding(.leading, showOnlyVolumes ? 0 : 48)
          }
        }
      }
    }
    // Not an @EnvironmentObject: observing DriveManager here would redraw
    // every disk on any of its changes, and only this subject is needed.
    .onReceive(DriveManager.shared.driveExpansionSubject) { expanded in
      withAnimation {
        self.isExpanded = expanded
      }
    }
  }
}
