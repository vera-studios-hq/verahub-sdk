import Foundation

/// Turns the app's visibility reports into offer views: an offer visible for one second is one
/// view, once per feed load and offer, and only with analytics consent.
final class ViewTracker: Sendable {
  struct Key: Hashable {
    let feedId: String
    let offerId: String
  }

  private struct State {
    var analytics: Bool
    var ended = false
    var visible: [Key: (id: UUID, timer: Task<Void, Never>)] = [:]
    var viewed: Set<Key> = []
  }

  /// How long an offer must stay visible to count as viewed.
  static let viewDuration = 1.0

  private let state: Locked<State>
  private let clock: any SDKClock
  private let log: Log
  private let viewed: @Sendable (WireClientEvent) -> Void

  init(
    analytics: Bool, clock: any SDKClock, log: Log,
    viewed: @escaping @Sendable (WireClientEvent) -> Void
  ) {
    state = Locked(State(analytics: analytics))
    self.clock = clock
    self.log = log
    self.viewed = viewed
  }

  func becameVisible(_ offer: Offer) {
    guard let feedId = offer.feedId else {
      log.debug("Offer \(offer.id) was not loaded from a list; its visibility is not counted.")
      return
    }
    let key = Key(feedId: feedId, offerId: offer.id)
    state.withLock { state in
      guard state.analytics, !state.ended, !state.viewed.contains(key), state.visible[key] == nil
      else { return }
      let id = UUID()
      let timer = Task { [weak self, clock] in
        guard (try? await clock.sleep(seconds: Self.viewDuration)) != nil else { return }
        self?.elapsed(key, id: id)
      }
      state.visible[key] = (id, timer)
    }
  }

  func becameHidden(_ offer: Offer) {
    guard let feedId = offer.feedId else { return }
    let key = Key(feedId: feedId, offerId: offer.id)
    state.withLock { $0.visible.removeValue(forKey: key)?.timer.cancel() }
  }

  /// Without analytics consent, running timers stop and new reports are ignored.
  func setAnalytics(_ analytics: Bool) {
    state.withLock { state in
      state.analytics = analytics
      if !analytics { Self.stopAll(&state) }
    }
  }

  func end() {
    state.withLock { state in
      state.ended = true
      Self.stopAll(&state)
    }
  }

  private static func stopAll(_ state: inout State) {
    for (_, entry) in state.visible { entry.timer.cancel() }
    state.visible.removeAll()
  }

  private func elapsed(_ key: Key, id: UUID) {
    let counts = state.withLock { state in
      guard state.visible[key]?.id == id, state.analytics, !state.ended else { return false }
      state.visible.removeValue(forKey: key)
      return state.viewed.insert(key).inserted
    }
    guard counts else { return }
    log.debug("Offer \(key.offerId) was viewed in feed \(key.feedId).")
    viewed(
      WireClientEvent(
        id: UUID().uuidString.lowercased(), name: "offerViewed", occurredAt: clock.now(),
        properties: ["offerId": key.offerId, "feedId": key.feedId]))
  }
}

/// Sends the consent and the queued events. Consent is sent when the client starts and on each
/// change; events leave the device only with analytics consent, and only after the consent was
/// sent. The queue is in memory: it is sent every few seconds, when it is full, and when the app
/// goes to the background, and a batch that failed a few times is dropped.
///
/// A send VeraHub or the connection cannot take now, or that the token callback or VeraHub's
/// refusal of the token stopped, pauses every send for a growing time. A send VeraHub refuses
/// for good, such as an invalid request, stops the client's own sends, and drops the queue,
/// until the consent changes.
actor EventPipeline {
  /// Seconds between sends.
  static let interval = 5.0
  /// Queued events that trigger a send at once.
  static let batchSize = 20
  /// The API takes at most this many events per request.
  static let requestLimit = 100
  /// The most events held; the oldest go first.
  static let capacity = 500
  /// Failed sends after which an event is dropped.
  static let attempts = 3
  /// The pause after a first failed send, in seconds; each next one doubles it.
  static let firstPause = 5.0
  /// The longest pause, in seconds.
  static let longestPause = 300.0

  private struct Queued {
    let event: WireClientEvent
    var failures = 0
  }

  private enum Outcome {
    /// Not a failure: the send no longer applied, or the client ended.
    case ignore
    /// A pause, at least `retryAfter` seconds.
    case pause(retryAfter: Double?)
    case stop
  }

  private let session: Session
  /// The newest consent and its number, set without waiting, so changes keep their order.
  private let consent: Locked<(value: Consent, version: Int)>
  private var sentVersion: Int?
  private var queue: [Queued] = []
  private var flushing = false
  private var flushAgain = false
  private var ended = false
  private var loop: Task<Void, Never>?
  private var failedSends = 0
  private var pausedUntil: Date?
  private var stopped = false
  /// The consent number the pause or stop belongs to; a newer consent lifts both.
  private var pausedVersion = 0

  init(session: Session, consent: Consent) {
    self.session = session
    self.consent = Locked((consent, 0))
  }

  /// Sends the consent now and then the queue every few seconds, until the client ends.
  func start() {
    guard loop == nil, !ended else { return }
    loop = Task { [weak self, clock = session.clock] in
      await self?.flush()
      while !Task.isCancelled {
        guard (try? await clock.sleep(seconds: Self.interval)) != nil, let pipeline = self else {
          return
        }
        await pipeline.flush()
      }
    }
  }

  /// Records a change of consent at once and sends it soon; an unchanged consent is not sent.
  nonisolated func setConsent(_ consent: Consent) {
    let changed = self.consent.withLock { current in
      guard current.value != consent else { return false }
      current = (consent, current.version + 1)
      return true
    }
    if changed { Task { await flush() } }
  }

  func enqueue(_ event: WireClientEvent) {
    guard consent.withLock({ $0.value.analytics }), !ended, !stopped else { return }
    queue.append(Queued(event: event))
    if queue.count > Self.capacity {
      session.log.error("The event queue is full; dropping the oldest offer view.")
      queue.removeFirst(queue.count - Self.capacity)
    }
    if queue.count >= Self.batchSize { Task { await flush() } }
  }

  func end() {
    ended = true
    queue.removeAll()
    loop?.cancel()
    loop = nil
  }

  /// Sends the consent if it has not been sent, then the queue in batches; does nothing while
  /// sends are paused or stopped.
  func flush() async {
    guard !ended else { return }
    guard !flushing else {
      flushAgain = true
      return
    }
    flushing = true
    defer { flushing = false }
    repeat {
      flushAgain = false
      guard mayFlush() else { return }
      await flushOnce()
    } while flushAgain && !ended
  }

  private func mayFlush() -> Bool {
    let version = consent.withLock { $0.version }
    if version != pausedVersion {
      pausedVersion = version
      failedSends = 0
      pausedUntil = nil
      stopped = false
    }
    if stopped { return false }
    if let pausedUntil, session.clock.now() < pausedUntil { return false }
    return true
  }

  private func flushOnce() async {
    let (current, version) = consent.withLock { $0 }
    if !current.analytics { queue.removeAll() }
    if sentVersion != version {
      do {
        let body = WireConsent(
          analytics: current.analytics, personalisation: current.personalisation)
        // A newer consent replaces this one, and is sent next.
        _ = try await session.dataOrProblem(
          .send("PUT", "consent") { body }
            .only { [consent] in consent.withLock { $0.version } == version })
        sentVersion = version
        succeeded()
      } catch {
        switch Self.outcome(of: error) {
        case .ignore:
          break
        case .pause(let retryAfter):
          session.log.error("Sending the consent failed; it is sent again later: \(error)")
          pause(retryAfter: retryAfter)
        case .stop:
          session.log.error(
            "VeraHub refused the consent; it is sent again when it changes: \(error)"
          )
          stop()
        }
        return
      }
    }

    while sentVersion == consent.withLock({ $0.version }), consent.withLock({ $0.value.analytics }),
      !ended, !queue.isEmpty
    {
      let batch = queue.prefix(Self.requestLimit).map(\.event)
      let ids = Set(batch.map(\.id))
      do {
        // `sentAt` is stamped at each attempt, so the server can correct the device's clock.
        _ = try await session.dataOrProblem(
          .send("POST", "events") { [clock = session.clock] in
            WireSendEvents(sentAt: clock.now(), events: batch)
          }
          .only { [consent] in consent.withLock { $0.value.analytics } })
        queue.removeAll { ids.contains($0.event.id) }
        succeeded()
      } catch {
        switch Self.outcome(of: error) {
        case .ignore:
          if !consent.withLock({ $0.value.analytics }) { queue.removeAll() }
          return
        case .pause(let retryAfter):
          let before = queue.count
          queue = queue.compactMap { queued in
            guard ids.contains(queued.event.id) else { return queued }
            var queued = queued
            queued.failures += 1
            return queued.failures < Self.attempts ? queued : nil
          }
          let dropped = before - queue.count
          session.log.error(
            "Sending \(batch.count) offer views failed\(dropped > 0 ? "; dropped \(dropped)" : ""): \(error)"
          )
          pause(retryAfter: retryAfter)
        case .stop:
          session.log.error(
            "VeraHub refused \(batch.count) offer views; no more are sent: \(error)")
          stop()
        }
        return
      }
    }
  }

  private func succeeded() {
    failedSends = 0
    pausedUntil = nil
  }

  private func pause(retryAfter: Double?) {
    failedSends += 1
    let growing = min(Self.firstPause * pow(2, Double(failedSends - 1)), Self.longestPause)
    pausedUntil = session.clock.now().addingTimeInterval(max(growing, retryAfter ?? 0))
  }

  private func stop() {
    stopped = true
    queue.removeAll()
  }

  /// What a failed send means for the next ones.
  private static func outcome(of error: any Error) -> Outcome {
    if error is CancellationError || error is Abandoned { return .ignore }
    if let problem = error as? Problem {
      let refusedToken = ["user-mismatch", "user-token-invalid", "user-token-expired"]
      if problem.status == 429 || problem.status >= 500
        || refusedToken.contains(problem.code ?? "")
      {
        return .pause(retryAfter: problem.retryAfter)
      }
      return .stop
    }
    if let error = error as? VeraHubError {
      if error.kind == .signedOut { return .ignore }
      if error.kind == .noConnection || (error.kind == .unexpected && error.status == nil) {
        return .pause(retryAfter: nil)
      }
      return .stop
    }
    // The token callback's own error.
    return .pause(retryAfter: nil)
  }
}
