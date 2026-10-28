//  Created by homielab.com

/// Tracks which `show()` of a shared HUD panel is the current one.
///
/// Every show starts a new generation. The delayed hide and the `orderOut`
/// at the end of its fade-out both belong to the generation that scheduled
/// them, and only run while that generation is still current, so a message
/// shown during an earlier message's fade-out is not hidden with it.
struct HUDVisibility: Sendable, Equatable {
  private(set) var generation = 0

  /// Starts a new generation and returns it; earlier ones become stale.
  mutating func show() -> Int {
    generation += 1
    return generation
  }

  /// Whether a hide step scheduled by `generation` may still run.
  func isCurrent(_ generation: Int) -> Bool {
    generation == self.generation
  }
}
