//  Created by homielab.com

import SwiftUI

struct CircularProgressRing: View {
  let progress: Double
  let color: Color
  let lineWidth: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static func usageColor(for percentage: Double) -> Color {
    if percentage > 0.9 { return .red } else if percentage > 0.75 { return .orange }
    return .accentColor
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(
          color.opacity(0.3),
          lineWidth: lineWidth
        )
      Circle()
        .trim(from: 0, to: max(0.0, min(1.0, progress)))
        .stroke(
          color,
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round
          )
        )
        .rotationEffect(.degrees(-90))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(Self.usedLabel(for: progress)))
  }

  /// VoiceOver text such as "42% used".
  static func usedLabel(for progress: Double, bundle: Bundle = .main) -> String {
    let percent = Int((max(0.0, min(1.0, progress)) * 100).rounded())
    return String(
      format: NSLocalizedString(
        "Accessibility Percent Used", bundle: bundle, comment: "VoiceOver value of a usage ring"),
      percent)
  }
}
