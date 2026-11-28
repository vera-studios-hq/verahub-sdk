// An app's view of the SDK: no `@testable`, Foundation (and SwiftUI where it exists) imported
// next to it, and every public type named in type position, where a clash with a type of the
// same name in those modules (Objective-C's `Category`, SwiftUI's `Image`) would be ambiguous.
import Foundation
import Testing
import VeraHub

#if canImport(SwiftUI)
  import SwiftUI
#endif

@Suite struct PublicTypeNameTests {
  @Test func everyPublicTypeCanBeNamedInAnApp() {
    let categories: [Category] = []
    let offers: [Offer] = []
    let images: [RemoteImage] = []
    let brands: [Brand] = []
    let offerImages: [OfferImages] = []
    let offerCategories: [OfferCategory] = []
    let benefits: [Benefit] = []
    let kinds: [BenefitKind] = [.coupon]
    let clickOuts: [ClickOut] = []
    let details: [OfferDetail] = []
    let benefitsForUser: [BenefitForUser] = []
    let holdings: [Holding] = []
    let coupons: [HoldingCoupon] = []
    let entries: [HoldingEntry] = []
    let heldBenefits: [HeldBenefit] = []
    let heldOffers: [HeldOffer] = []
    let results: [RevealResult] = []
    let reasons: [RevealUnavailableReason] = [.soldOut]
    let errors: [VeraHubError] = []
    let errorKinds: [VeraHubError.Kind] = [.listExpired]
    let environments: [VeraHubEnvironment] = [.sandbox]
    let levels: [VeraHubLogLevel] = [.off]
    let consents: [Consent] = []
    let lists: [PagedList<Offer>] = []
    let clients: [VeraHubClient] = []
    var total = 0
    total += categories.count
    total += offers.count
    total += images.count
    total += brands.count
    total += offerImages.count
    total += offerCategories.count
    total += benefits.count
    total += kinds.count
    total += clickOuts.count
    total += details.count
    total += benefitsForUser.count
    total += holdings.count
    total += coupons.count
    total += entries.count
    total += heldBenefits.count
    total += heldOffers.count
    total += results.count
    total += reasons.count
    total += errors.count
    total += errorKinds.count
    total += environments.count
    total += levels.count
    total += consents.count
    total += lists.count
    total += clients.count
    #expect(total == 5)
  }
}
