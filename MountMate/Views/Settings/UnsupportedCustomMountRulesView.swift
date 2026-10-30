//  Created by homielab.com

import SwiftUI

/// Warns about custom mount point rules an older version wrote in
/// /etc/fstab for a file system that may no longer get one (NTFS,
/// third-party drivers), each with a Remove Rule button. Nothing is removed
/// without the user: removing asks for the administrator password.
struct UnsupportedCustomMountRulesView: View {
  let rules: [FstabRules.CustomMountRule]
  /// Saved custom mount points, for the volume names.
  let savedEntries: [VolumeCustomMountPoint]
  let removingIDs: Set<String>
  let onRemove: (FstabRules.CustomMountRule) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.headline)
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text("Unsafe Custom Mount Rules")
          .font(.headline)
      }

      Text("Unsafe Custom Mount Rules Explanation")
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      VStack(spacing: 8) {
        ForEach(rules) { rule in
          row(rule)
          if rule != rules.last {
            Divider()
          }
        }
      }
    }
    .padding(14)
    .background(Color.orange.opacity(0.08))
    .clipShape(.rect(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
    )
  }

  private func name(of rule: FstabRules.CustomMountRule) -> String {
    savedEntries.first { $0.id == rule.identifier }?.name ?? rule.mountPoint
  }

  private func row(_ rule: FstabRules.CustomMountRule) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name(of: rule))
          .font(.body)
          .bold()
        HStack(spacing: 8) {
          Text(rule.mountPoint)
          Text(
            String(
              format: NSLocalizedString(
                "File System: %@", comment: "File system type of an /etc/fstab rule"),
              rule.fileSystemType))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }
      .accessibilityElement(children: .combine)

      Spacer()

      if removingIDs.contains(rule.id) {
        ProgressView()
          .controlSize(.small)
      } else {
        Button(NSLocalizedString("Remove Rule", comment: "Removes an /etc/fstab rule")) {
          onRemove(rule)
        }
        .accessibilityLabel(
          String(
            format: NSLocalizedString(
              "Remove “%@”", comment: "Accessibility label of a saved entry's remove button"),
            name(of: rule)))
      }
    }
    .padding(.vertical, 4)
  }
}
