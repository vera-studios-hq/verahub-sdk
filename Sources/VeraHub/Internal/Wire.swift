import Foundation

// The JSON of the publisher API, kept apart from the public types so this layer can change, or be
// generated, without changing what apps see. Unknown fields are ignored; requests carry only the
// fields the spec names, and leave an optional field out rather than sending null.

struct WireImage: Decodable {
  let url: URL
  let width: Int
  let height: Int

  var model: RemoteImage { RemoteImage(url: url, width: width, height: height) }
}

struct WireBrand: Decodable {
  let name: String
  let logo: WireImage
  let logoWide: WireImage?

  var model: Brand { Brand(name: name, logo: logo.model, logoWide: logoWide?.model) }
}

struct WireOfferImages: Decodable {
  let wide: WireImage
  let square: WireImage
  let tall: WireImage

  var model: OfferImages { OfferImages(wide: wide.model, square: square.model, tall: tall.model) }
}

struct WireOfferCategory: Decodable {
  let key: String
  let name: String
}

struct WireBenefit: Decodable {
  let id: String
  let kind: String
  let valueText: String
  let title: String
  let conditions: String?
  let endsAt: Date?

  /// `nil` for a kind this SDK version cannot show.
  var model: Benefit? {
    let kind = BenefitKind(rawValue: kind)
    guard BenefitKind.supported.contains(kind) else { return nil }
    return Benefit(
      id: id, kind: kind, valueText: valueText, title: title, conditions: conditions,
      endsAt: endsAt)
  }
}

struct WireOffer: Decodable {
  let id: String
  let brand: WireBrand
  let valueText: String
  let title: String
  let subline: String?
  let description: String
  let images: WireOfferImages
  let categories: [WireOfferCategory]
  let benefits: [WireBenefit]

  func model(feedId: String?) -> Offer {
    Offer(
      id: id, brand: brand.model, valueText: valueText, title: title, subline: subline,
      description: description, images: images.model,
      categories: categories.map { OfferCategory(key: $0.key, name: $0.name) },
      benefits: benefits.compactMap(\.model), feedId: feedId)
  }
}

struct WireOfferList: Decodable {
  let items: [WireOffer]
  let feedId: String
  let nextCursor: String?
}

struct WireCategory: Decodable {
  let key: String
  let name: String
  let offerCount: Int
}

struct WireCategoryList: Decodable {
  let items: [WireCategory]
}

struct WireClickOut: Decodable {
  let url: URL
}

struct WireBenefitForUser: Decodable {
  let benefitId: String
  let nextRevealAt: Date?
  let clickOut: WireClickOut?
}

struct WireOfferForUser: Decodable {
  let benefits: [WireBenefitForUser]
  let holdings: [WireHoldingEntry]
}

struct WireOfferDetail: Decodable {
  let offer: WireOffer
  let user: WireOfferForUser

  func model(feedId: String?) -> OfferDetail {
    let offer = offer.model(feedId: feedId)
    let shown = Set(offer.benefits.map(\.id))
    return OfferDetail(
      offer: offer,
      benefits: user.benefits.filter { shown.contains($0.benefitId) }.map {
        BenefitForUser(
          benefitId: $0.benefitId, nextRevealAt: $0.nextRevealAt,
          clickOut: $0.clickOut.map { ClickOut(url: $0.url) })
      },
      holdings: user.holdings.compactMap(\.model))
  }
}

struct WireHolding: Decodable {
  struct Coupon: Decodable {
    let code: String
  }

  let id: String
  let kind: String
  let benefitId: String
  let offerId: String
  let heldAt: Date
  let expiresAt: Date?
  let expired: Bool
  let clickOut: WireClickOut?
  let coupon: Coupon?

  /// `nil` for a kind this SDK version cannot show.
  var model: Holding? {
    let kind = BenefitKind(rawValue: kind)
    guard BenefitKind.supported.contains(kind) else { return nil }
    return Holding(
      id: id, kind: kind, benefitId: benefitId, offerId: offerId, heldAt: heldAt,
      expiresAt: expiresAt, isExpired: expired, clickOut: clickOut.map { ClickOut(url: $0.url) },
      coupon: coupon.map { HoldingCoupon(code: $0.code) })
  }
}

struct WireHeldBenefit: Decodable {
  let valueText: String
  let title: String
  let conditions: String?
}

struct WireHeldOffer: Decodable {
  let id: String
  let listed: Bool
  let brand: WireBrand
}

struct WireHoldingEntry: Decodable {
  let holding: WireHolding
  let benefit: WireHeldBenefit
  let offer: WireHeldOffer

  var model: HoldingEntry? {
    holding.model.map {
      HoldingEntry(
        holding: $0,
        benefit: HeldBenefit(
          valueText: benefit.valueText, title: benefit.title, conditions: benefit.conditions),
        offer: HeldOffer(id: offer.id, isListed: offer.listed, brand: offer.brand.model))
    }
  }
}

struct WireHoldingList: Decodable {
  let items: [WireHoldingEntry]
  let nextCursor: String?
}

struct WireRevealResult: Decodable {
  let outcome: String
  let holding: WireHolding
  let nextRevealAt: Date?

  var model: RevealResult {
    guard let holding = holding.model else { return .unavailable(.other) }
    switch outcome {
    case "already-held": return .alreadyHeld(holding, nextRevealAt: nextRevealAt)
    case "cooldown":
      if let nextRevealAt { return .cooldown(holding, nextRevealAt: nextRevealAt) }
      return .alreadyHeld(holding, nextRevealAt: nil)
    // `allocated`, and an outcome this version does not know, which the spec says is a success.
    default: return .revealed(holding, nextRevealAt: nextRevealAt)
    }
  }
}

struct WireConsent: Codable, Sendable {
  let analytics: Bool
  let personalisation: Bool
}

struct WireSendEvents: Encodable, Sendable {
  let sentAt: Date
  let events: [WireClientEvent]
}

struct WireClientEvent: Encodable, Sendable {
  let id: String
  let name: String
  let occurredAt: Date
  let properties: [String: String]
}

struct WireProblem: Decodable {
  let code: String?
  let detail: String?
  let requestId: String?
  let nextRevealAt: Date?
}

enum JSON {
  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = ISODate.parse(text) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Not an RFC 3339 date-time: \(text)")
      }
      return date
    }
    return decoder
  }()

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(ISODate.format(date))
    }
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
}

enum ISODate {
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let whole = Date.ISO8601FormatStyle()

  static func parse(_ text: String) -> Date? {
    (try? fractional.parse(text)) ?? (try? whole.parse(text))
  }

  /// UTC with milliseconds, as the API writes dates.
  static func format(_ date: Date) -> String { fractional.format(date) }
}
