import Foundation

/// The time and waiting, so tests can move time on by hand. (`Clock` needs iOS 16.)
package protocol SDKClock: Sendable {
  func now() -> Date
  /// Waits, or throws `CancellationError` when the task is cancelled.
  func sleep(seconds: Double) async throws
}

struct SystemClock: SDKClock {
  func now() -> Date { Date() }

  func sleep(seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
  }
}
