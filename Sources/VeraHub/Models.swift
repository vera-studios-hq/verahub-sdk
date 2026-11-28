import Foundation

/// An end user's consent, as the app has collected it.
public struct Consent: Sendable, Hashable {
  /// Whether the user's activity may be measured. Without it, no offer view leaves the device.
  public var analytics: Bool
  /// Whether offers may be personalised to the user.
  public var personalisation: Bool

  public init(analytics: Bool, personalisation: Bool) {
    self.analytics = analytics
    self.personalisation = personalisation
  }
}

/// A kind of benefit. This SDK version shows coupons only, and asks the API for nothing else.
public struct BenefitKind: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  /// A code to enter at the brand's checkout.
  public static let coupon = BenefitKind(rawValue: "coupon")

  /// The kinds this SDK version can show, sent with every request that returns benefits.
  static let supported: [BenefitKind] = [.coupon]

  public var description: String { rawValue }
}

/// An image on the web with its size in pixels. Its URL is absolute and immutable: load it
/// unaltered. (Not named `Image`, so it does not clash with SwiftUI's.)
public struct RemoteImage: Sendable, Hashable {
  public let url: URL
  public let width: Int
  public let height: Int
}

/// The brand behind an offer.
public struct Brand: Sendable, Hashable {
  /// Up to 40 characters.
  public let name: String
  /// Square, 512 × 512, on an opaque background.
  public let logo: RemoteImage
  /// 3:1, 768 × 256, on an opaque background; fall back to ``logo``.
  public let logoWide: RemoteImage?
}

/// One image of an offer in three ratios; use the one your layout needs.
public struct OfferImages: Sendable, Hashable {
  /// 16:9, 1600 × 900.
  public let wide: RemoteImage
  /// 1:1, 1080 × 1080.
  public let square: RemoteImage
  /// 3:4, 1080 × 1440.
  public let tall: RemoteImage
}

/// A category an offer belongs to.
public struct OfferCategory: Sendable, Hashable {
  /// A stable key such as `sports-outdoors`, never changed or reused. Keys can be added and
  /// retired: map the keys you know to your own icons and show a fallback for others.
  public let key: String
  /// The German name, which can change.
  public let name: String
}

/// A category with the number of offers listed in it, from ``VeraHubClient/categories()``.
public struct CategorySummary: Sendable, Hashable, Identifiable {
  /// A stable key such as `sports-outdoors`; pass it to ``VeraHubClient/offers(category:)``.
  public let key: String
  /// The German name, which can change.
  public let name: String
  /// How many offers ``VeraHubClient/offers(category:)`` lists for it; hide a category with 0.
  public let offerCount: Int

  public var id: String { key }
}

/// What a user can get from an offer.
public struct Benefit: Sendable, Hashable, Identifiable {
  public let id: String
  /// The benefit's kind; ``BenefitKind/coupon`` in this SDK version.
  public let kind: BenefitKind
  /// The short value, up to 16 characters, such as "25 %".
  public let valueText: String
  /// Up to 60 characters.
  public let title: String
  /// What applies to it, up to 500 characters. Make it reachable before the user reveals it.
  public let conditions: String?
  /// When it can no longer be revealed; `nil` while no end is set.
  public let endsAt: Date?
}

/// An offer of a brand, with its benefits.
///
/// Its texts can differ per user and per request: do not keep them across users. Texts are
/// German plain text.
public struct Offer: Sendable, Hashable, Identifiable {
  public let id: String
  public let brand: Brand
  /// The short value, up to 16 characters, such as "bis zu 25 %".
  public let valueText: String
  /// Up to 60 characters.
  public let title: String
  /// Up to 100 characters.
  public let subline: String?
  /// Plain text, up to 600 characters.
  public let description: String
  public let images: OfferImages
  /// One to three, the main category first.
  public let categories: [OfferCategory]
  /// Every benefit the user can get from the offer, in VeraHub's order.
  public let benefits: [Benefit]
  /// The feed load the offer was listed in, which its views and its detail name.
  let feed: FeedLoad?

  var feedId: String? { feed?.id }
}

/// One load of an offer list from its first page: its id, the same on every page, and when the
/// SDK loaded it.
struct FeedLoad: Sendable, Hashable {
  let id: String
  let loadedAt: Date

  func isExpired(at now: Date) -> Bool {
    now.timeIntervalSince(loadedAt) >= ViewTracker.feedLifetime
  }
}

/// Where a tap on a benefit or a holding leads.
public struct ClickOut: Sendable, Hashable {
  /// Open it unaltered in the system browser or an in-app browser tab (`SFSafariViewController`),
  /// never in a web view. Valid as long as the app shows the offer; fetch it again with the offer.
  public let url: URL
}

/// An offer with what belongs to the user, from ``VeraHubClient/offerDetail(for:)``.
public struct OfferDetail: Sendable, Hashable {
  /// The offer in the same shape as in the list.
  public let offer: Offer
  /// One entry per benefit in `offer.benefits`, in the same order.
  public let benefits: [BenefitForUser]
  /// What the user holds from any of the offer's benefits, newest first, also from benefits no
  /// longer listed.
  public let holdings: [HoldingEntry]

  /// The user's state of one of the offer's benefits.
  public func user(of benefit: Benefit) -> BenefitForUser? {
    benefits.first { $0.benefitId == benefit.id }
  }
}

/// One benefit of an offer as it stands for the user.
public struct BenefitForUser: Sendable, Hashable {
  public let benefitId: String
  /// While a cooldown runs, when the user can reveal the benefit for a new code; `nil` when a
  /// reveal answers at once.
  public let nextRevealAt: Date?
  /// Where a tap leads; always present for a coupon.
  public let clickOut: ClickOut?
}

/// A benefit the user holds, such as a revealed coupon code.
public struct Holding: Sendable, Hashable, Identifiable {
  public let id: String
  public let kind: BenefitKind
  public let benefitId: String
  public let offerId: String
  /// When the user received it.
  public let heldAt: Date
  /// When it stops working at the brand's shop; `nil` if it never does.
  public let expiresAt: Date?
  /// Whether ``expiresAt`` has passed. Expired holdings stay; hide them if you like.
  public let isExpired: Bool
  /// Where a tap leads; always present for a coupon.
  public let clickOut: ClickOut?
  /// The coupon, when ``kind`` is ``BenefitKind/coupon``.
  public let coupon: HoldingCoupon?
}

/// A coupon the user holds.
public struct HoldingCoupon: Sendable, Hashable {
  /// The code to enter at the brand's checkout. Show it unaltered.
  public let code: String
}

/// A holding with the benefit and offer it came from, as the holdings list shows it.
public struct HoldingEntry: Sendable, Hashable, Identifiable {
  public let holding: Holding
  public let benefit: HeldBenefit
  public let offer: HeldOffer

  public var id: String { holding.id }
}

/// The benefit a holding came from.
public struct HeldBenefit: Sendable, Hashable {
  public let valueText: String
  public let title: String
  public let conditions: String?
}

/// The offer a holding came from.
public struct HeldOffer: Sendable, Hashable {
  public let id: String
  /// Whether the offer is listed for the user now, so its detail can be opened.
  public let isListed: Bool
  public let brand: Brand
}
