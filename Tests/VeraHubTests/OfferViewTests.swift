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
        ? .problem("request-invalid") : .ok("responses/replaceConsent.200")
    }
    let harness = ViewHarness(api: api)
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(12)
    #expect(harness.sentViews.isEmpty)

    consentFails.withLock { $0 = false }
    await harness.pass(6)
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
