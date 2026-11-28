import Foundation
import Testing
import VeraHub
import VeraHubPreview

@Suite struct PreviewTests {
  @Test func showsTheSampleOffersAndCategoriesWithoutABackend() async throws {
    let client = VeraHubPreview(latency: 0).client
    let offers = try await client.offers().loadNext()
    #expect(offers.map(\.brand.name) == ["Alpenwerk"])
    #expect(try await client.offers(category: "pets").loadNext().isEmpty)
    #expect(try await client.offers(category: "fashion").loadNext().count == 1)
    #expect(try await client.categories().first?.key == "fashion")
    let detail = try await client.offerDetail(for: offers[0])
    #expect(detail.benefits.count == 2)
  }

  @Test func codesAreVisiblyFake() async throws {
    let client = VeraHubPreview(latency: 0).client
    let holdings = try await client.holdings().loadNext()
    #expect(holdings.count == 1)
    #expect(holdings.allSatisfy { $0.holding.coupon?.code.hasPrefix("PREVIEW-") == true })
  }

  @Test func revealGivesANewCodeOnceAndThenTheSameHolding() async throws {
    let client = VeraHubPreview(latency: 0).client
    let offer = try #require(try await client.offers().loadNext().first)
    let notHeld = offer.benefits[1]

    let first = try await client.reveal(notHeld)
    guard case .revealed(let holding, _) = first else {
      Issue.record("expected revealed, got \(first)")
      return
    }
    #expect(holding.coupon?.code.hasPrefix("PREVIEW-") == true)
    #expect(holding.benefitId == notHeld.id)
    #expect(try await client.reveal(notHeld) == .alreadyHeld(holding, nextRevealAt: nil))
    let held = try await client.holdings().loadNext()
    #expect(held.first?.holding == holding)
    #expect(held.first?.benefit.title == "10 % auf alles")
    #expect(try await client.offerDetail(for: offer).holdings.count == 2)
  }

  @Test func revealCanAnswerUnavailable() async throws {
    let client = VeraHubPreview(reveal: .unavailable(.soldOut), latency: 0).client
    let offer = try #require(try await client.offers().loadNext().first)
    #expect(try await client.reveal(offer.benefits[0]) == .unavailable(.soldOut))
  }

  @Test func anUnknownOfferIsNotFound() async throws {
    let client = VeraHubPreview(latency: 0).client
    do {
      _ = try await client.offerDetail(offerId: "nope")
      Issue.record("Expected offerNotFound")
    } catch let error as VeraHubError {
      #expect(error.kind == .offerNotFound)
    }
  }

  @Test func recordsTheViewsAndTheConsentTheClientSends() async throws {
    let preview = VeraHubPreview(
      consent: Consent(analytics: true, personalisation: false), latency: 0)
    let offer = try #require(try await preview.client.offers().loadNext().first)
    preview.client.offerBecameVisible(offer)
    // The preview runs on the real clock: one second visible, then the next send.
    try await Task.sleep(nanoseconds: 6_500_000_000)
    #expect(preview.sentViews.map(\.offerId) == [offer.id])
    #expect(preview.sentConsent == Consent(analytics: true, personalisation: false))
  }
}
