import Foundation
import Testing

@testable import VeraHub

@Suite struct CatalogueTests {
  @Test func offersReadTheListFixture() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers", .ok(json: lastPage("responses/listOffers.200")))
    let offers = try await makeClient(api).offers().loadNext()

    let offer = try #require(offers.first)
    #expect(offers.count == 1)
    #expect(offer.id == "019a8f2e-3a02-7f18-a4b6-1d9c8e5f2a70")
    #expect(offer.brand.name == "Alpenwerk")
    #expect(
      offer.brand.logo.url.absoluteString == "https://media.verahub.io/i/4f7c1e9a2b6d8f03.webp")
    #expect(offer.brand.logoWide?.width == 768)
    #expect(offer.subline == "Für die ganze Familie")
    #expect(offer.images.tall.height == 1440)
    #expect(offer.categories.map(\.key) == ["sports-outdoors", "fashion"])
    #expect(offer.benefits.map(\.valueText) == ["25 %", "10 %"])
    #expect(offer.benefits[0].kind == .coupon)
    #expect(offer.benefits[0].endsAt == date("2027-03-31T21:59:59.000Z"))
    #expect(offer.benefits[1].conditions == nil)
    #expect(offer.feedId == "019a8f30-1e44-7c09-b2a8-5d6f3e9c1a27")
  }

  @Test func offerDetailReadsTheDetailFixtureAndKeepsTheFeedLoad() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers", .ok(json: lastPage("responses/listOffers.200")))
    api.on(
      "GET", "/v1/me/offers/019a8f2e-3a02-7f18-a4b6-1d9c8e5f2a70", .ok("responses/getOffer.200"))
    let client = makeClient(api)
    let offer = try #require(try await client.offers().loadNext().first)

    let detail = try await client.offerDetail(for: offer)

    #expect(detail.offer.title == "25 % auf Wanderschuhe")
    #expect(detail.offer.feedId == offer.feedId)
    let first = try #require(detail.user(of: detail.offer.benefits[0]))
    #expect(first.nextRevealAt == date("2026-12-23T09:30:00.000Z"))
    #expect(
      first.clickOut?.url.absoluteString
        == "https://go.verahub.de/c/Z_5x3itlMvapTalKrIRGLVRHZb_y2YHV")
    #expect(detail.user(of: detail.offer.benefits[1])?.nextRevealAt == nil)
    let held = try #require(detail.holdings.first)
    #expect(held.holding.coupon?.code == "ALPEN-7K4Q-92XD")
    #expect(held.offer.isListed)
  }

  @Test func offerDetailByIdHasNoFeedLoad() async throws {
    let api = FakeAPI()
    api.on(
      "GET", "/v1/me/offers/019a8f2e-3a02-7f18-a4b6-1d9c8e5f2a70", .ok("responses/getOffer.200"))
    let detail = try await makeClient(api).offerDetail(
      offerId: "019a8f2e-3a02-7f18-a4b6-1d9c8e5f2a70")
    #expect(detail.offer.feedId == nil)
  }

  @Test func categoriesReadTheCategoryFixture() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/categories", .ok("responses/listCategories.200"))
    let categories = try await makeClient(api).categories()
    #expect(
      categories.first == Category(key: "fashion", name: "Mode & Accessoires", offerCount: 12))
    #expect(
      categories.count
        == (json(fixture("responses/listCategories.200")) as! [String: [Any]])["items"]!.count)
  }

  @Test func holdingsReadTheHoldingsFixture() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/holdings", .ok(json: lastPage("responses/listHoldings.200")))
    let entries = try await makeClient(api).holdings().loadNext()
    let entry = try #require(entries.first)
    #expect(entry.holding.coupon?.code == "ALPEN-7K4Q-92XD")
    #expect(entry.holding.heldAt == date("2026-11-23T09:30:00.000Z"))
    #expect(entry.holding.isExpired == false)
    #expect(entry.benefit.title == "25 % auf Wanderschuhe")
    #expect(entry.offer.brand.name == "Alpenwerk")
  }

  @Test func everyRequestNamesTheUserTheSdkAndTheBenefitKinds() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers", .ok(json: lastPage("responses/listOffers.200")))
    api.on("GET", "/v1/me/categories", .ok("responses/listCategories.200"))
    api.on("GET", "/v1/me/holdings", .ok(json: lastPage("responses/listHoldings.200")))
    api.on("GET", "/v1/me/offers/o-1", .ok("responses/getOffer.200"))
    api.on("POST", "/v1/me/benefits/b-1/reveal", .ok("responses/revealBenefit.200"))
    let client = makeClient(api, userId: "u-48151623", token: TokenCallback("t-a"))

    _ = try await client.offers(category: "fashion").loadNext()
    _ = try await client.categories()
    _ = try await client.holdings().loadNext()
    _ = try await client.offerDetail(offerId: "o-1")
    _ = try await client.reveal(benefitId: "b-1")

    let calls = api.received.filter { $0.path != "/v1/me/consent" }
    #expect(calls.count == 5)
    for call in calls {
      #expect(call.headers["Authorization"] == "Bearer t-a")
      #expect(call.headers["VeraHub-Expected-User"] == "u-48151623")
      let names = headerNames(try #require(call.headers["VeraHub-Client"]))
      #expect(Set(names).isSubset(of: ["sdk", "os", "app", "build", "device", "locale", "tz"]))
      #expect(
        call.headers["VeraHub-Client"]?.hasPrefix(
          "sdk=\"swift/\(VeraHubClient.sdkVersion)\", os=\"") == true)
    }
    for call in calls where call.method == "GET" {
      #expect(call.query["benefitKinds"] == ["coupon"])
    }
    #expect(api.received("GET", "/v1/me/offers")[0].query["category"] == ["fashion"])
    #expect(api.received("POST", "/v1/me/benefits/b-1/reveal")[0].query.isEmpty)
  }

  /// The member names of an RFC 9651 dictionary of strings; commas inside a quoted value
  /// (a device such as `Mac14,2`) do not separate members.
  private func headerNames(_ header: String) -> [String] {
    var names: [String] = []
    var member = ""
    var quoted = false
    var escaped = false
    for character in header + "," {
      if character == "," && !quoted {
        names.append(
          String(member.split(separator: "=", maxSplits: 1)[0]).trimmingCharacters(
            in: .whitespaces))
        member = ""
        continue
      }
      member.append(character)
      if escaped {
        escaped = false
      } else if quoted && character == "\\" {
        escaped = true
      } else if character == "\"" {
        quoted.toggle()
      }
    }
    return names
  }

  @Test func clientHeaderValuesAreAsciiStringsOfAtMost128Characters() {
    #expect(ClientContext.quoted("Zürich \"x\" \\") == #""Z?rich \"x\" \\""#)
    #expect(ClientContext.quoted(String(repeating: "a", count: 200)).count == 130)
    #expect(ClientContext.bcp47("de_DE") == "de-DE")
    #expect(ClientContext.bcp47("en_US@calendar=japanese") == "en-US")
  }

  @Test func pagingFollowsTheCursorAndKeepsTheFirstPagesFeedLoad() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers") { request in
      request.query["cursor"] == nil
        ? .ok(json: page(offerIds: ["o-1", "o-2"], feedId: "feed-a", next: "c-2"))
        : .ok(json: page(offerIds: ["o-3"], feedId: "feed-b", next: nil))
    }
    let offers = makeClient(api).offers()

    let first = try await offers.loadNext()
    #expect(await offers.isComplete == false)
    let second = try await offers.loadNext()
    let third = try await offers.loadNext()

    #expect(first.map(\.id) == ["o-1", "o-2"])
    #expect(second.map(\.id) == ["o-3"])
    #expect(third.isEmpty)
    #expect(await offers.isComplete)
    #expect(await offers.items.map(\.id) == ["o-1", "o-2", "o-3"])
    #expect(Set((first + second).map(\.feedId)) == ["feed-a"])
    #expect(api.received("GET", "/v1/me/offers").map { $0.query["cursor"] ?? [] } == [[], ["c-2"]])
  }

  @Test func concurrentPageLoadsReturnEachPageOnce() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers") { request in
      let cursor = request.query["cursor"]?.first
      let index = cursor.map { Int($0.dropFirst(2))! } ?? 1
      return .ok(
        json: page(offerIds: ["o-\(index)"], feedId: "f", next: index < 3 ? "c-\(index + 1)" : nil))
    }
    let offers = makeClient(api).offers()

    async let a = offers.loadNext()
    async let b = offers.loadNext()
    async let c = offers.loadNext()
    let pages = try await [a, b, c]

    #expect(pages.flatMap { $0 }.map(\.id).sorted() == ["o-1", "o-2", "o-3"])
  }

  @Test func aFailedPageIsLoadedAgainByTheNextCall() async throws {
    let api = FakeAPI()
    let failures = Locked(1)
    api.on("GET", "/v1/me/holdings") { _ in
      failures.withLock { failures in
        defer { failures -= 1 }
        return failures > 0
          ? .problem("request-invalid") : .ok(json: lastPage("responses/listHoldings.200"))
      }
    }
    let holdings = makeClient(api).holdings()
    await #expect(throws: VeraHubError.self) { try await holdings.loadNext() }
    #expect(try await holdings.loadNext().count == 1)
  }
}

/// A list fixture without its `nextCursor`, as the last page.
func lastPage(_ name: String) -> String {
  var list = json(fixture(name)) as! [String: Any]
  list.removeValue(forKey: "nextCursor")
  return String(decoding: try! JSONSerialization.data(withJSONObject: list), as: UTF8.self)
}

/// An offer list page of copies of the fixture's offer.
func page(offerIds: [String], feedId: String, next: String?) -> String {
  let list = json(fixture("responses/listOffers.200")) as! [String: Any]
  let offer = (list["items"] as! [[String: Any]])[0]
  var page: [String: Any] = [
    "items": offerIds.map { id in offer.merging(["id": id]) { $1 } }, "feedId": feedId,
  ]
  if let next { page["nextCursor"] = next }
  return String(decoding: try! JSONSerialization.data(withJSONObject: page), as: UTF8.self)
}

func date(_ text: String) -> Date { ISODate.parse(text)! }
