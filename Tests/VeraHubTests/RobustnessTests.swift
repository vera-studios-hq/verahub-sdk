import Foundation
import Testing

@testable import VeraHub

@Suite struct IdTests {
  @Test(arguments: ["", ".", "..", String(repeating: "x", count: 65)])
  func anIdNoOfferCanHaveIsNotFoundWithoutARequest(id: String) async throws {
    let api = FakeAPI()
    let client = makeClient(api)
    let detail = await veraHubError { try await client.offerDetail(offerId: id) }
    #expect(detail?.kind == .offerNotFound)
    let reveal = await veraHubError { try await client.reveal(benefitId: id) }
    #expect(reveal?.kind == .offerNotFound)
    #expect(api.received.allSatisfy { $0.path == "/v1/me/consent" })
  }

  @Test func anIdIsOnePathSegment() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers/../holdings?x", .ok("responses/getOffer.200"))
    let client = makeClient(api)
    _ = try? await client.offerDetail(offerId: "../holdings?x")
    _ = try? await client.offerDetail(offerId: "a/b%2F")
    _ = try? await client.reveal(benefitId: "b/../c")
    let paths = api.received.map(\.rawPath).filter { $0 != "/v1/me/consent" }
    #expect(
      paths == [
        "/v1/me/offers/..%2Fholdings%3Fx", "/v1/me/offers/a%2Fb%252F",
        "/v1/me/benefits/b%2F..%2Fc/reveal",
      ])
  }
}

@Suite struct LenientListTests {
  @Test func anUnreadableOfferIsSkippedAndTheOthersShown() async throws {
    var list = json(fixture("responses/listOffers.200")) as! [String: Any]
    let offer = (list["items"] as! [[String: Any]])[0]
    var broken = offer
    broken["id"] = "broken"
    broken.removeValue(forKey: "title")
    list["items"] = [broken, offer]
    list.removeValue(forKey: "nextCursor")
    let api = FakeAPI()
    api.on(
      "GET", "/v1/me/offers",
      Answer(status: 200, body: try JSONSerialization.data(withJSONObject: list)))

    let offers = try await makeClient(api).offers().loadNext()
    #expect(offers.map(\.id) == ["019a8f2e-3a02-7f18-a4b6-1d9c8e5f2a70"])
  }

  @Test func anUnreadableOptionalImageIsLeftOut() async throws {
    var list = json(fixture("responses/listOffers.200")) as! [String: Any]
    var offer = (list["items"] as! [[String: Any]])[0]
    var brand = offer["brand"] as! [String: Any]
    brand["logoWide"] = ["url": 5, "width": 768, "height": 256]
    offer["brand"] = brand
    list["items"] = [offer]
    list.removeValue(forKey: "nextCursor")
    let api = FakeAPI()
    api.on(
      "GET", "/v1/me/offers",
      Answer(status: 200, body: try JSONSerialization.data(withJSONObject: list)))

    let loaded = try #require(try await makeClient(api).offers().loadNext().first)
    #expect(loaded.brand.logoWide == nil)
    #expect(loaded.brand.logo.width == 512)
  }
}

@Suite struct ExpiredListTests {
  @Test func aCursorVeraHubCannotContinueEndsTheListWithListExpired() async throws {
    let api = FakeAPI()
    var firstPage = json(fixture("responses/listHoldings.200")) as! [String: Any]
    firstPage["nextCursor"] = "c-2"
    let first = try JSONSerialization.data(withJSONObject: firstPage)
    api.on("GET", "/v1/me/holdings") { request in
      request.query["cursor"] == nil ? Answer(status: 200, body: first) : .problem("cursor-invalid")
    }
    let holdings = makeClient(api).holdings()
    #expect(try await holdings.loadNext().count == 1)

    let expired = await veraHubError { try await holdings.loadNext() }
    let again = await veraHubError { try await holdings.loadNext() }

    #expect(expired?.kind == .listExpired)
    #expect(again?.kind == .listExpired)
    #expect(await holdings.isComplete == false)
    #expect(api.received("GET", "/v1/me/holdings").count == 2)
  }

  @Test func cursorInvalidOnAFirstPageIsUnexpected() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/holdings", .problem("cursor-invalid"))
    let error = await veraHubError { try await makeClient(api).holdings().loadNext() }
    #expect(error?.kind == .unexpected)
  }
}

@Suite struct ConsentWithdrawalTests {
  @Test func viewsQueuedBeforeAWithdrawalNeverLeaveAfterConsentReturns() async throws {
    let harness = ViewHarness()
    let offers = try await harness.feed()
    harness.client.offerBecameVisible(offers[0])
    await harness.timersWaiting(2)
    await harness.pass(1.5)

    harness.client.updateConsent(Consent(analytics: false, personalisation: false))
    harness.client.updateConsent(Consent(analytics: true, personalisation: false))
    await harness.pass(10)

    #expect(harness.sentViews.isEmpty)
  }

  @Test func aBatchBeingRetriedStopsAtAWithdrawalAlsoWhenConsentReturns() async throws {
    let api = FakeAPI()
    let gate = Gate()
    let calls = Locked(0)
    api.on("POST", "/v1/me/events") { _ in
      let call = calls.withLock { calls in
        calls += 1
        return calls
      }
      if call == 1 {
        await gate.wait()
        return .problem("temporarily-unavailable")
      }
      return .noContent
    }
    let harness = ViewHarness(api: api)
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(6)
    await eventually("the first send") { calls.withLock { $0 } == 1 }

    harness.client.updateConsent(Consent(analytics: false, personalisation: false))
    harness.client.updateConsent(Consent(analytics: true, personalisation: false))
    await gate.open()
    await harness.pass(40)

    #expect(calls.withLock { $0 } == 1)
  }
}

@Suite struct FeedAgeTests {
  @Test func anOfferOfAFeedLoadOverADayOldIsNotCounted() async throws {
    let harness = ViewHarness()
    let offer = try await harness.feed()[0]
    await harness.timersWaiting(1)
    harness.clock.advance(by: 23 * 3600)
    await settle()

    harness.client.offerBecameVisible(offer)
    await harness.pass(10)
    #expect(harness.sentViews.isEmpty)
  }

  @Test func aQueuedViewWhoseFeedLoadAgesOutIsDropped() async throws {
    let api = FakeAPI()
    let failing = Locked(true)
    api.on("POST", "/v1/me/events") { _ in
      failing.withLock { $0 } ? .problem("temporarily-unavailable") : .noContent
    }
    let harness = ViewHarness(api: api)
    let offer = try await harness.feed()[0]
    harness.client.offerBecameVisible(offer)
    await harness.timersWaiting(2)
    await harness.pass(8)
    await eventually("a failed send") { !api.received("POST", "/v1/me/events").isEmpty }
    let failedSends = api.received("POST", "/v1/me/events").count

    failing.withLock { $0 = false }
    harness.clock.advance(by: 23 * 3600)
    await harness.pass(10)

    #expect(api.received("POST", "/v1/me/events").count == failedSends)
  }
}
