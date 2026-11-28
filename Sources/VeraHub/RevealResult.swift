import Foundation

/// What revealing a benefit gave the user, from ``VeraHubClient/reveal(_:)``.
public enum RevealResult: Sendable, Hashable {
  /// The user received the holding now. `nextRevealAt` is when they can reveal the benefit for
  /// a new code, `nil` when they never can.
  case revealed(Holding, nextRevealAt: Date?)
  /// The user held it already; it is returned again.
  case alreadyHeld(Holding, nextRevealAt: Date?)
  /// The user gets a new code only from `nextRevealAt`; the holding is their latest.
  case cooldown(Holding, nextRevealAt: Date)
  /// The user cannot get the benefit now.
  case unavailable(RevealUnavailableReason)

  /// The holding the user has from the benefit, unless it is ``unavailable(_:)``.
  public var holding: Holding? {
    switch self {
    case .revealed(let holding, _), .alreadyHeld(let holding, _), .cooldown(let holding, _):
      holding
    case .unavailable:
      nil
    }
  }
}

/// Why a benefit cannot be revealed now.
public enum RevealUnavailableReason: Sendable, Hashable {
  /// No codes are left.
  case soldOut
  /// The benefit is not available to your app right now.
  case quotaReached
  /// The benefit is not offered to this user now.
  case notAvailable
  /// The user has reached a limit for the benefit; `until` is when it lifts, if known.
  case limitReached(until: Date?)
  /// A reason this SDK version does not know; treat it like ``notAvailable``.
  case other
}
