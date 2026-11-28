import Foundation
import VeraHub

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A ``VeraHub/VeraHubClient`` that answers from sample data, with no network and no backend: to
/// build and preview screens before your backend issues tokens.
///
/// The sample data are the publisher spec's examples, the fixtures every VeraHub SDK is tested
/// against. Codes start with `PREVIEW-` and work in no shop. Use it in debug builds, SwiftUI
/// previews, and tests only; a release build should not link this module.
///
/// ```swift
/// #Preview {
///   OfferList(client: VeraHubPreview().client)
/// }
/// ```
public final class VeraHubPreview: Sendable {
  /// What a reveal answers in the preview.
  public enum RevealBehaviour: Sendable, Hashable {
    /// A benefit the user holds is returned again; any other gives them a new code.
    case succeed
    /// Every reveal answers as if the benefit were unavailable for this reason.
    case unavailable(RevealUnavailableReason)
  }

  /// An offer view the client sent, as VeraHub would have received it.
  public struct SentView: Sendable, Hashable {
    public let offerId: String
    public let feedId: String
    public let occurredAt: Date
  }

  /// The client to pass to your screens.
  public let client: VeraHubClient
  private let server: PreviewServer

  /// Creates a preview client.
  ///
  /// - Parameters:
  ///   - userId: The end user the client acts for.
  ///   - consent: The consent the user has given.
  ///   - reveal: What a reveal answers.
  ///   - latency: Seconds each answer takes, to show your loading states.
  public init(
    userId: String = "preview-user",
    consent: Consent = Consent(analytics: true, personalisation: true),
    reveal: RevealBehaviour = .succeed,
    latency: Double = 0.3
  ) {
    let server = PreviewServer(reveal: reveal, latency: latency)
    self.server = server
    client = VeraHubClient(
      userId: userId, consent: consent, token: { _ in "preview-token" }, transport: server)
  }

  /// The offer views the client has sent so far: offers your app reported visible for a second.
  public var sentViews: [SentView] { server.sentViews }

  /// The consent the client sent last, or `nil` before it sent one.
  public var sentConsent: Consent? { server.sentConsent }
}

extension VeraHubClient {
  /// A client on sample data, from ``VeraHubPreview``.
  public static func preview(
    consent: Consent = Consent(analytics: true, personalisation: true)
  ) -> VeraHubClient {
    VeraHubPreview(consent: consent).client
  }
}
