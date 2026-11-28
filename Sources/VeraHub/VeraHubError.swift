import Foundation

/// The error the client's calls throw. Branch on ``kind``; show users your own words, not
/// ``message``, which is for developers.
///
/// A reveal that does not give the user a holding is not an error: it is a ``RevealResult``.
/// An error thrown by your token callback is rethrown unchanged by the call that needed the token;
/// the client calls the callback again for a later call, and, after growing pauses, for its own
/// background sends.
public struct VeraHubError: Error, Sendable, CustomStringConvertible {
  /// What went wrong, as a value to branch on. New kinds can be added in a minor version.
  public struct Kind: Sendable, Hashable, CustomStringConvertible {
    let name: String

    /// The device has no connection to the internet. Try again once it has.
    public static let noConnection = Kind(name: "noConnection")
    /// VeraHub cannot answer right now, also after retrying. Try again later.
    public static let serviceUnavailable = Kind(name: "serviceUnavailable")
    /// The client was signed out with ``VeraHubClient/signOut()``. Create a new one.
    public static let signedOut = Kind(name: "signedOut")
    /// The user no longer exists at VeraHub: your backend deleted them. Create a new client
    /// once your backend has a token for them again.
    public static let userDeleted = Kind(name: "userDeleted")
    /// The token your callback returned belongs to another user than the client's `userId`.
    /// Nothing was shown; the next call asks your callback for a token again.
    public static let userMismatch = Kind(name: "userMismatch")
    /// The offer or benefit is no longer listed for the user. Reload the list.
    public static let offerNotFound = Kind(name: "offerNotFound")
    /// This SDK version is no longer served. Update the app's VeraHub SDK.
    public static let sdkUnsupported = Kind(name: "sdkUnsupported")
    /// The client is set up wrongly: an invalid `userId`, or tokens VeraHub refuses, such as
    /// tokens of another environment. The message says which.
    public static let misconfigured = Kind(name: "misconfigured")
    /// VeraHub answered something this SDK version does not understand. Quote the request id
    /// when reporting it.
    public static let unexpected = Kind(name: "unexpected")

    public var description: String { name }
  }

  public let kind: Kind
  /// What happened and what to do, in English, for developers.
  public let message: String
  /// The id of the request VeraHub answered, to quote when reporting a problem.
  public let requestId: String?
  /// The HTTP status VeraHub answered with, if it answered.
  public let status: Int?
  /// The problem code VeraHub answered with, if any.
  public let problemCode: String?

  init(
    _ kind: Kind, _ message: String, requestId: String? = nil, status: Int? = nil,
    problemCode: String? = nil
  ) {
    self.kind = kind
    self.message = message
    self.requestId = requestId
    self.status = status
    self.problemCode = problemCode
  }

  public var description: String {
    var text = "VeraHubError.\(kind): \(message)"
    if let status { text += " (status \(status)" + (problemCode.map { ", \($0)" } ?? "") + ")" }
    if let requestId { text += " [request \(requestId)]" }
    return text
  }
}

extension VeraHubError: LocalizedError {
  public var errorDescription: String? { description }
}
