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

  @Test func recordsTheViewsTheClientSends() async throws {
    let preview = VeraHubPreview(
      userId: "preview-user", consent: Consent(analytics: true, personalisation: false),
      reveal: .succeed, latency: 0, clock: RunawayClock())
    let offer = try #require(try await preview.client.offers().loadNext().first)
    preview.client.offerBecameVisible(offer)
    for _ in 0..<500 where preview.sentViews.isEmpty {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(preview.sentViews.map(\.offerId) == [offer.id])
  }
}

/// A clock whose waits take no real time: each one moves its time on by the wait.
private final class RunawayClock: SDKClock, @unchecked Sendable {
  private let lock = NSLock()
  private var offset = 0.0

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return Date(timeIntervalSinceNow: offset)
  }

  private func advance(by seconds: Double) {
    lock.lock()
    defer { lock.unlock() }
    offset += seconds
  }

  func sleep(seconds: Double) async throws {
    try Task.checkCancellation()
    advance(by: max(0, seconds))
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}
