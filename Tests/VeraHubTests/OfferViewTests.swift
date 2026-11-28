import Foundation
import Testing

@testable import VeraHub

/// A client with offers loaded from one feed load, on a manual clock.
struct ViewHarness {
  let api: FakeAPI
  let clock = ManualClock()
  let client: VeraHubClient

  init(
    consent: Consent = Consent(analytics: true, personalisation: false), api: FakeAPI = FakeAPI()
  ) {
    self.api = api
    api.on("GET", "/v1/me/offers") { _ in
      .ok(
        json: page(
          offerIds: ["o-1", "o-2"], feedId: "feed-\(UUID().uuidString.prefix(8))", next: nil))
    }
    client = makeClient(api, consent: consent, clock: clock)
  }

  func feed() async throws -> [Offer] { try await client.offers().loadNext() }

  var sentViews: [[String: String]] {
    api.received("POST", "/v1/me/events").flatMap { request in
      (request.bodyJSON["events"] as! [[String: Any]]).map { $0["properties"] as! [String: String] }
    }
  }

  /// Moves time on in steps, letting the client's timers run between them.
  func pass(_ seconds: Double) async {
    var left = seconds
    while left > 0 {
      let step = min(left, 0.5)
      clock.advance(by: step)
      left -= step
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// Waits until every timer the client started has reached its sleep.
  func timersWaiting(_ count: Int) async {
    await eventually("\(count) timers") { clock.waiting >= count }
  }
}

@Suite struct OfferViewTests {
  @Test func anOfferScrolledPastInUnderASecondSendsNoView() async throws {
    let harness = ViewHarness()
    let offer = try await harness.feed()[0]

    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(0.5)
    harness.client.offerBecameHidden(offer)
    await harness.pass(10)

    #expect(harness.sentViews.isEmpty)
  }

  @Test func anOfferThatStaysSendsExactlyOneViewPerFeedLoad() async throws {
    let harness = ViewHarness()
    let offer = try await harness.feed()[0]

    for _ in 0..<3 {
      harness.client.offerBecameVisible(offer)
      await harness.timersWaiting(1)
      await harness.pass(1.5)
      harness.client.offerBecameHidden(offer)
    }
    await harness.pass(6)

    #expect(harness.sentViews == [["offerId": "o-1", "feedId": offer.feedId!]])

    // A new feed load counts the offer once more.
    let reloaded = try await harness.feed()[0]
    harness.client.offerBecameVisible(reloaded)
    await harness.timersWaiting(2)
    await harness.pass(6)
    #expect(harness.sentViews.map { $0["feedId"] } == [offer.feedId, reloaded.feedId])
  }

  @Test func theEventsRequestMatchesTheSpecsExample() async throws {
    let harness = ViewHarness()
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(6)

    let request = try #require(harness.api.received("POST", "/v1/me/events").first)
    let example = json(fixture("requests/sendEvents")) as! [String: Any]
    let body = request.bodyJSON
    #expect(Set(body.keys) == Set(example.keys))
    let event = (body["events"] as! [[String: Any]])[0]
    let exampleEvent = (example["events"] as! [[String: Any]])[0]
    #expect(Set(event.keys) == Set(exampleEvent.keys))
    #expect(event["name"] as? String == "offerViewed")
    #expect(Set((event["properties"] as! [String: String]).keys) == ["offerId", "feedId"])
    #expect(ISODate.parse(event["occurredAt"] as! String) != nil)
  }

  @Test func withoutAnalyticsConsentNoViewLeavesTheDevice() async throws {
    let harness = ViewHarness(consent: Consent(analytics: false, personalisation: true))
    let offers = try await harness.feed()

    for offer in offers { harness.client.offerBecameVisible(offer) }
    await harness.pass(20)

    #expect(harness.api.received("POST", "/v1/me/events").isEmpty)
    #expect(
      harness.api.received("PUT", "/v1/me/consent").map { $0.bodyJSON["analytics"] as? Bool } == [
        false
      ])
  }

  @Test func withdrawingConsentDropsViewsNotYetSent() async throws {
    let harness = ViewHarness()
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(1.5)

    harness.client.updateConsent(Consent(analytics: false, personalisation: false))
    await harness.pass(10)

    #expect(harness.api.received("POST", "/v1/me/events").isEmpty)
    #expect(
      harness.api.received("PUT", "/v1/me/consent").last?.bodyJSON["analytics"] as? Bool == false)
  }

  @Test func consentIsSentAtStartAndOnEachChangeOnly() async throws {
    let harness = ViewHarness()
    await eventually("the consent at start") {
      harness.api.received("PUT", "/v1/me/consent").count == 1
    }
    harness.client.updateConsent(Consent(analytics: true, personalisation: false))
    harness.client.updateConsent(Consent(analytics: true, personalisation: true))
    await harness.pass(11)

    let sent = harness.api.received("PUT", "/v1/me/consent").map { Set($0.bodyJSON.keys) }
    #expect(sent == [["analytics", "personalisation"], ["analytics", "personalisation"]])
    #expect(
      harness.api.received("PUT", "/v1/me/consent").last?.bodyJSON["personalisation"] as? Bool
        == true)
  }

  @Test func viewsWaitForTheConsentToBeSent() async throws {
    let api = FakeAPI()
    let consentFails = Locked(true)
    api.on("PUT", "/v1/me/consent") { _ in
      consentFails.withLock { $0 }
        ? .problem("temporarily-unavailable") : .ok("responses/replaceConsent.200")
    }
    let harness = ViewHarness(api: api)
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(12)
    #expect(harness.sentViews.isEmpty)

    consentFails.withLock { $0 = false }
    await harness.pass(30)
    #expect(harness.sentViews.count == 1)
  }

  @Test func sentAtIsStampedAtEachAttemptAndAFailingBatchIsDropped() async throws {
    let api = FakeAPI()
    api.on("POST", "/v1/me/events", .problem("internal-server-error"))
    let harness = ViewHarness(api: api)
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(40)

    let attempts = api.received("POST", "/v1/me/events")
    // Three sends of the batch, each retried by the session three times.
    #expect(attempts.count == EventPipeline.attempts * Session.attempts)
    let stamps = attempts.map { $0.bodyJSON["sentAt"] as! String }
    #expect(Set(stamps).count == stamps.count)
  }

  @Test func offersNotFromAListAreNotCounted() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers/o-1", .ok("responses/getOffer.200"))
    let harness = ViewHarness(api: api)
    let offer = try await harness.client.offerDetail(offerId: "o-1").offer
    harness.client.offerBecameVisible(offer)
    await harness.pass(10)
    #expect(harness.sentViews.isEmpty)
  }

  @Test func signingOutDropsViewsAndTimers() async throws {
    let harness = ViewHarness()
    let offers = try await harness.feed()
    harness.client.offerBecameVisible(offers[0])
    await harness.timersWaiting(2)
    await harness.pass(1.5)
    harness.client.offerBecameVisible(offers[1])
    harness.client.signOut()
    await harness.pass(10)
    #expect(harness.sentViews.isEmpty)
  }
}

extension ViewHarness {
  /// Moves time on in small steps until the fake API has received `count` of `method path`.
  func pass(untilReceived count: Int, _ method: String, _ path: String) async {
    var steps = 0
    while api.received(method, path).count < count && steps < 200 {
      clock.advance(by: 0.5)
      steps += 1
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}

/// What the client's own sends do when something changes or fails while they are under way.
@Suite struct BackgroundSendTests {
  private static let withdrawn = Consent(analytics: false, personalisation: false)

  /// A view of the first offer, queued and sent by the periodic send.
  private func viewQueued(_ harness: ViewHarness) async throws {
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(1.5)
  }

  @Test func withdrawingConsentStopsTheRetriesOfASendUnderWay() async throws {
    let api = FakeAPI()
    api.on("POST", "/v1/me/events", .problem("temporarily-unavailable"))
    let harness = ViewHarness(api: api)
    try await viewQueued(harness)
    await harness.pass(untilReceived: 1, "POST", "/v1/me/events")

    harness.client.updateConsent(Self.withdrawn)
    await harness.pass(30)

    #expect(api.received("POST", "/v1/me/events").count == 1)
    #expect(api.received("PUT", "/v1/me/consent").last?.bodyJSON["analytics"] as? Bool == false)
  }

  @Test func signingOutStopsTheRetriesOfASendUnderWay() async throws {
    let api = FakeAPI()
    api.on("POST", "/v1/me/events", .problem("temporarily-unavailable"))
    let harness = ViewHarness(api: api)
    try await viewQueued(harness)
    await harness.pass(untilReceived: 1, "POST", "/v1/me/events")

    harness.client.signOut()
    await harness.pass(30)

    #expect(api.received("POST", "/v1/me/events").count == 1)
  }

  @Test func aCallThatIsRetriedStopsWhenTheClientSignsOut() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/categories", .problem("temporarily-unavailable"))
    let clock = ManualClock()
    let client = makeClient(api, clock: clock)
    let call = Task { try await client.categories() }
    await eventually("the first attempt") {
      api.received("GET", "/v1/me/categories").count == 1 && clock.waiting >= 2
    }

    client.signOut()
    clock.advance(by: 5)

    let error = await veraHubError { try await call.value }
    #expect(error?.kind == .signedOut)
    #expect(api.received("GET", "/v1/me/categories").count == 1)
  }

  @Test func aClientThatIsReleasedStopsTheRetriesOfASendUnderWay() async throws {
    let api = FakeAPI()
    api.on("POST", "/v1/me/events", .problem("temporarily-unavailable"))
    let clock = ManualClock()
    api.on("GET", "/v1/me/offers") { _ in
      .ok(json: page(offerIds: ["o-1"], feedId: "feed-1", next: nil))
    }
    var client: VeraHubClient? = makeClient(api, clock: clock)
    let offer = try await client!.offers().loadNext()[0]
    client?.offerBecameVisible(offer)
    await eventually("the timers") { clock.waiting >= 2 }
    var steps = 0
    while api.received("POST", "/v1/me/events").isEmpty && steps < 200 {
      clock.advance(by: 0.5)
      steps += 1
      try? await Task.sleep(nanoseconds: 20_000_000)
    }

    client = nil
    for _ in 0..<60 {
      clock.advance(by: 0.5)
      try? await Task.sleep(nanoseconds: 20_000_000)
    }

    #expect(api.received("POST", "/v1/me/events").count == 1)
  }

  @Test func aNewerConsentReplacesOneThatIsBeingRetried() async throws {
    let api = FakeAPI()
    let puts = Locked(0)
    api.on("PUT", "/v1/me/consent") { _ in
      let number = puts.withLock { puts -> Int in
        puts += 1
        return puts
      }
      return number == 1
        ? .problem("temporarily-unavailable") : .ok("responses/replaceConsent.200")
    }
    let harness = ViewHarness(api: api)
    await eventually("the first consent") { api.received("PUT", "/v1/me/consent").count == 1 }

    harness.client.updateConsent(Consent(analytics: true, personalisation: true))
    await harness.pass(3)

    let sent = api.received("PUT", "/v1/me/consent").map { $0.bodyJSON["personalisation"] as? Bool }
    // The old consent is not sent again, and the new one is sent without a pause.
    #expect(sent == [false, true])
  }

  @Test func sendsPauseLongerAfterEachFailure() async throws {
    let api = FakeAPI()
    api.on("PUT", "/v1/me/consent", .problem("temporarily-unavailable"))
    let harness = ViewHarness(api: api)
    await eventually("the first consent") { !api.received("PUT", "/v1/me/consent").isEmpty }

    // Each round is three attempts of the session; the second round waits 10 seconds, not 5.
    await harness.pass(16)
    #expect(api.received("PUT", "/v1/me/consent").count == 2 * Session.attempts)
    await harness.pass(10)
    #expect(api.received("PUT", "/v1/me/consent").count == 3 * Session.attempts)
  }

  @Test func aTokenVeraHubRefusesIsAskedForAgainAfterGrowingPauses() async throws {
    let api = FakeAPI()
    api.on("PUT", "/v1/me/consent", .problem("user-token-invalid"))
    let token = TokenCallback("t-1")
    let clock = ManualClock()
    let client = makeClient(api, clock: clock, token: token)
    defer { client.signOut() }
    await eventually("the first consent") { !api.received("PUT", "/v1/me/consent").isEmpty }

    for _ in 0..<24 {
      clock.advance(by: 0.5)
      try? await Task.sleep(nanoseconds: 20_000_000)
    }

    // At the start, after 5 seconds, and after 15 more; not every 5 seconds.
    #expect(token.calls == 2)
  }

  @Test func aRetryAfterLongerThanThePauseIsKept() async throws {
    let api = FakeAPI()
    api.on("PUT", "/v1/me/consent", .problem("rate-limited", headers: ["Retry-After": "30"]))
    let harness = ViewHarness(api: api)
    await eventually("the first consent") { !api.received("PUT", "/v1/me/consent").isEmpty }

    await harness.pass(25)
    #expect(api.received("PUT", "/v1/me/consent").count == 1)
    await harness.pass(15)
    #expect(api.received("PUT", "/v1/me/consent").count == 2)
  }

  @Test func aRefusedConsentStopsTheSendsUntilTheConsentChanges() async throws {
    let api = FakeAPI()
    let refused = Locked(true)
    api.on("PUT", "/v1/me/consent") { _ in
      refused.withLock { $0 } ? .problem("user-not-found") : .ok("responses/replaceConsent.200")
    }
    let harness = ViewHarness(api: api)
    let offers = try await harness.feed()
    harness.client.offerBecameVisible(offers[0])
    await harness.timersWaiting(2)
    await harness.pass(60)
    #expect(api.received("PUT", "/v1/me/consent").count == 1)
    #expect(harness.sentViews.isEmpty)

    refused.withLock { $0 = false }
    harness.client.updateConsent(Consent(analytics: true, personalisation: true))
    await eventually("the consent to be sent again") {
      api.received("PUT", "/v1/me/consent").count == 2
    }
    harness.client.offerBecameVisible(offers[1])
    await harness.timersWaiting(1)
    await harness.pass(10)

    // The view from while the sends were stopped is gone; the one after is sent.
    #expect(harness.sentViews == [["offerId": "o-2", "feedId": offers[1].feedId!]])
  }

  @Test func refusedViewsStopTheSendsAndAreDropped() async throws {
    let api = FakeAPI()
    api.on("POST", "/v1/me/events", .problem("request-invalid"))
    let harness = ViewHarness(api: api)
    let offers = try await harness.feed()
    harness.client.offerBecameVisible(offers[0])
    await harness.timersWaiting(2)
    await harness.pass(10)
    harness.client.offerBecameVisible(offers[1])
    await harness.timersWaiting(1)
    await harness.pass(60)

    #expect(api.received("POST", "/v1/me/events").count == 1)
  }
}
