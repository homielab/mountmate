//  Created by homielab.com

import SwiftUI

struct CircularProgressRing: View {
  let progress: Double
  let color: Color
  let lineWidth: CGFloat

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
        .animation(.easeInOut(duration: 0.3), value: progress)
    }
  }
}
