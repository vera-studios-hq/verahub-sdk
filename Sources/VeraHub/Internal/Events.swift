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

  private struct Queued {
    let event: WireClientEvent
    var failures = 0
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
    guard consent.withLock({ $0.value.analytics }), !ended else { return }
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

  /// Sends the consent if it has not been sent, then the queue in batches.
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
      await flushOnce()
    } while flushAgain && !ended
  }

  private func flushOnce() async {
    let (current, version) = consent.withLock { $0 }
    if !current.analytics { queue.removeAll() }
    if sentVersion != version {
      do {
        let body = WireConsent(
          analytics: current.analytics, personalisation: current.personalisation)
        _ = try await session.data(.send("PUT", "consent") { body })
        sentVersion = version
      } catch {
        session.log.error("Sending the consent failed; it is sent again shortly: \(error)")
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
        _ = try await session.data(
          .send("POST", "events") { [clock = session.clock] in
            WireSendEvents(sentAt: clock.now(), events: batch)
          })
        queue.removeAll { ids.contains($0.event.id) }
      } catch {
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
        return
      }
    }
  }
}
