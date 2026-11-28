import Foundation

/// The VeraHub client for one end user of your app.
///
/// Create one when a user signs in and keep it while they stay signed in; when they sign out or
/// another user signs in, call ``signOut()`` and create a new client. The client keeps nothing on
/// disk: its token, offer views, and timers live in memory and end with it.
///
/// ```swift
/// let client = VeraHubClient(environment: .sandbox, userId: user.id, consent: consent) { userId in
///   try await myBackend.verahubToken(for: userId)
/// }
/// let offers = client.offers()
/// let firstPage = try await offers.loadNext()
/// ```
public final class VeraHubClient: Sendable {
  /// This SDK's version, as it names itself to VeraHub.
  public static let sdkVersion = "0.1.0"

  /// The end user this client acts for.
  public let userId: String

  private let session: Session
  private let views: ViewTracker
  private let pipeline: EventPipeline
  private let observer: Locked<Observer?> = Locked(nil)

  /// Creates a client for one end user.
  ///
  /// - Parameters:
  ///   - environment: The deployment your backend's user tokens come from.
  ///   - userId: Your id of the user, as your backend names them when it asks VeraHub for a token:
  ///     1 to 128 letters, digits, `.`, `_`, `~`, or `-`, starting with a letter or digit.
  ///   - consent: The consent the user has given. Pass changes to ``updateConsent(_:)``.
  ///   - logLevel: How much the SDK writes to the system log; off by default.
  ///   - token: Returns a user token for `userId` from your backend. The client calls it when it
  ///     starts, because it then sends the consent; when VeraHub says the token expired; and
  ///     again, after growing pauses for its own background sends, after VeraHub refused a token
  ///     or the callback threw. An error it throws is rethrown by the call that needed the token.
  public convenience init(
    environment: VeraHubEnvironment, userId: String, consent: Consent,
    logLevel: VeraHubLogLevel = .off,
    token: @escaping @Sendable (_ userId: String) async throws -> String
  ) {
    self.init(
      environment: environment, userId: userId, consent: consent, logLevel: logLevel,
      token: token, transport: URLSessionTransport(), clock: SystemClock(),
      context: .current())
  }

  /// A client on another transport and clock, for the preview module and tests.
  package convenience init(
    userId: String, consent: Consent, logLevel: VeraHubLogLevel = .off,
    token: @escaping @Sendable (_ userId: String) async throws -> String,
    transport: any Transport, clock: (any SDKClock)? = nil
  ) {
    self.init(
      environment: .custom(URL(string: "https://publisher-api.invalid")!), userId: userId,
      consent: consent, logLevel: logLevel, token: token, transport: transport,
      clock: clock ?? SystemClock(), context: .current())
  }

  init(
    environment: VeraHubEnvironment, userId: String, consent: Consent, logLevel: VeraHubLogLevel,
    token: @escaping @Sendable (String) async throws -> String, transport: any Transport,
    clock: any SDKClock, context: ClientContext
  ) {
    let log = Log(level: logLevel)
    self.userId = userId
    session = Session(
      environment: environment, userId: userId, token: token, transport: transport, clock: clock,
      context: context, log: log)
    let pipeline = EventPipeline(session: session, consent: consent)
    self.pipeline = pipeline
    views = ViewTracker(analytics: consent.analytics, clock: clock, log: log) { event in
      Task { await pipeline.enqueue(event) }
    }
    Task { await pipeline.start() }
    observeBackground()
  }

  deinit {
    if let observer = observer.withLock({ $0 }) {
      NotificationCenter.default.removeObserver(observer.token)
    }
    session.markEnded()
    views.end()
    Task { [pipeline] in await pipeline.end() }
  }

  // MARK: Offers

  /// The offers listed for the user, newest feed load: each call starts a new one.
  ///
  /// - Parameter category: Only offers in this category, by its key; `nil` for all.
  public func offers(category: String? = nil) -> PagedList<Offer> {
    let feed = Locked<String?>(nil)
    return PagedList { [self] cursor in
      var query = Endpoint.benefitKinds
      if let category { query.append(URLQueryItem(name: "category", value: category)) }
      if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
      let page = try await session.decode(WireOfferList.self, .get("offers", query: query))
      // One feed load keeps the feedId of its first page.
      let feedId = feed.withLock { feed in
        if feed == nil { feed = page.feedId }
        return feed
      }
      return (page.items.map { $0.model(feedId: feedId) }, page.nextCursor)
    }
  }

  /// Every category, in VeraHub's order, each with the number of offers listed in it.
  public func categories() async throws -> [Category] {
    try await session.decode(
      WireCategoryList.self, .get("categories", query: Endpoint.benefitKinds)
    ).items.map(\.model)
  }

  /// The detail of an offer from a list, with what belongs to the user.
  public func offerDetail(for offer: Offer) async throws -> OfferDetail {
    try await offerDetail(offerId: offer.id, feedId: offer.feedId)
  }

  /// The detail of an offer by its id, for an offer opened from elsewhere, such as a deep link
  /// or a holding.
  public func offerDetail(offerId: String) async throws -> OfferDetail {
    try await offerDetail(offerId: offerId, feedId: nil)
  }

  private func offerDetail(offerId: String, feedId: String?) async throws -> OfferDetail {
    try await session.decode(
      WireOfferDetail.self, .get("offers", offerId, query: Endpoint.benefitKinds)
    ).model(feedId: feedId)
  }

  // MARK: Coupons

  /// Reveals a coupon to the user: gives them a code, or tells why they cannot get one now.
  public func reveal(_ benefit: Benefit) async throws -> RevealResult {
    try await reveal(benefitId: benefit.id)
  }

  /// Reveals a coupon by its benefit's id, such as a holding's ``Holding/benefitId`` after a
  /// cooldown.
  public func reveal(benefitId: String) async throws -> RevealResult {
    switch try await session.decodeOrProblem(
      WireRevealResult.self, .post("benefits", benefitId, "reveal"))
    {
    case .success(let answer):
      return try answer.model()
    case .failure(let problem):
      guard let reason = RevealUnavailableReason(problem) else {
        throw session.error(for: problem)
      }
      return .unavailable(reason)
    }
  }

  /// What the user holds, newest first.
  public func holdings() -> PagedList<HoldingEntry> {
    PagedList { [self] cursor in
      var query = Endpoint.benefitKinds
      if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
      let page = try await session.decode(WireHoldingList.self, .get("holdings", query: query))
      return (page.items.compactMap(\.model), page.nextCursor)
    }
  }

  // MARK: Consent and offer views

  /// Passes a change of the user's consent. The client sends it to VeraHub and, without
  /// analytics consent, stops counting offer views and drops those not yet sent.
  public func updateConsent(_ consent: Consent) {
    views.setAnalytics(consent.analytics)
    pipeline.setConsent(consent)
  }

  /// Reports that an offer of a list became at least half visible.
  ///
  /// An offer that stays visible for one second counts as one view, once per feed load. Report
  /// ``offerBecameHidden(_:)`` when less than half of it is visible again.
  public func offerBecameVisible(_ offer: Offer) {
    views.becameVisible(offer)
  }

  /// Reports that less than half of an offer is visible again.
  public func offerBecameHidden(_ offer: Offer) {
    views.becameHidden(offer)
  }

  // MARK: Ending

  /// Ends the client when its user signs out or another user signs in: drops the token, the
  /// offer views not yet sent, and the timers. Later calls throw ``VeraHubError/Kind/signedOut``.
  public func signOut() {
    views.end()
    let session = session
    Task { [pipeline] in
      await pipeline.end()
      await session.end()
    }
    session.markEnded()
  }

  /// Sends the queue when the app goes to the background. By the notification's name, so the
  /// SDK needs no UIKit and no main actor for it.
  private func observeBackground() {
    #if os(iOS) || os(tvOS) || os(visionOS)
      let pipeline = pipeline
      let token = NotificationCenter.default.addObserver(
        forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"), object: nil,
        queue: nil
      ) { _ in
        Task { await pipeline.flush() }
      }
      observer.withLock { $0 = Observer(token: token) }
    #endif
  }
}

/// A notification observer's token, which `NotificationCenter` uses from any thread.
private struct Observer: @unchecked Sendable {
  let token: any NSObjectProtocol
}
