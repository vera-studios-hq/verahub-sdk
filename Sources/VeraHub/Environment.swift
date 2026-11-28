import Foundation

/// The VeraHub deployment a client talks to. Its user tokens must come from the same one.
public struct VeraHubEnvironment: Sendable, Hashable {
  /// The address of the publisher API.
  public let baseURL: URL

  /// The deployment your users' apps use.
  public static let production = VeraHubEnvironment(
    baseURL: URL(string: "https://publisher-api.verahub.io")!)
  /// The deployment to build and test against, with a test catalogue whose codes work at no shop.
  public static let sandbox = VeraHubEnvironment(
    baseURL: URL(string: "https://publisher-api.sandbox.verahub.io")!)

  /// Another deployment, by the address of its publisher API.
  public static func custom(_ baseURL: URL) -> VeraHubEnvironment {
    VeraHubEnvironment(baseURL: baseURL)
  }
}

/// How much the SDK logs to the system log, under the subsystem `io.verahub.sdk`. Logs never
/// contain a token or a code.
public enum VeraHubLogLevel: Sendable, Hashable {
  case off
  /// Failed requests and dropped views.
  case error
  /// Also every request and its outcome.
  case info
  /// Also offer view timing and the event queue.
  case debug

  var rank: Int {
    switch self {
    case .off: 0
    case .error: 1
    case .info: 2
    case .debug: 3
    }
  }
}
