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

  private enum CodingKeys: String, CodingKey { case name, logo, logoWide }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    logo = try container.decode(WireImage.self, forKey: .logo)
    // An optional image this device cannot read is left out, as if it had none.
    logoWide = (try? container.decodeIfPresent(WireImage.self, forKey: .logoWide)) ?? nil
  }

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

  func model(feed: FeedLoad?) -> Offer {
    Offer(
      id: id, brand: brand.model, valueText: valueText, title: title, subline: subline,
      description: description, images: images.model,
      categories: categories.map { OfferCategory(key: $0.key, name: $0.name) },
      benefits: benefits.compactMap(\.model), feed: feed)
  }
}

/// One item of a list, or why this SDK version cannot read it: one unreadable item does not
/// fail its page.
struct Lossy<Item: Decodable>: Decodable {
  let item: Item?
  let failure: String?

  init(from decoder: any Decoder) throws {
    do {
      item = try Item(from: decoder)
      failure = nil
    } catch {
      item = nil
      failure = "\(error)"
    }
  }
}

extension Array {
  /// The items that could be read, logging those that could not.
  func readable<Item>(_ list: String, log: Log) -> [Item] where Element == Lossy<Item> {
    for failure in compactMap(\.failure) {
      log.error("Skipped an item of \(list) this SDK version cannot read: \(failure)")
    }
    return compactMap(\.item)
  }
}

struct WireOfferList: Decodable {
  let items: [Lossy<WireOffer>]
  let feedId: String
  let nextCursor: String?
}

struct WireCategory: Decodable {
  let key: String
  let name: String
  let offerCount: Int

  var model: Category { Category(key: key, name: name, offerCount: offerCount) }
}

struct WireCategoryList: Decodable {
  let items: [Lossy<WireCategory>]
}

struct WireClickOut: Decodable {
  let url: URL

  var model: ClickOut { ClickOut(url: url) }
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

  func model(feed: FeedLoad?) -> OfferDetail {
    let offer = offer.model(feed: feed)
    let shown = Set(offer.benefits.map(\.id))
    return OfferDetail(
      offer: offer,
      benefits: user.benefits.filter { shown.contains($0.benefitId) }.map {
        BenefitForUser(
          benefitId: $0.benefitId, nextRevealAt: $0.nextRevealAt,
          clickOut: $0.clickOut?.model)
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
      expiresAt: expiresAt, isExpired: expired, clickOut: clickOut?.model,
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
  let items: [Lossy<WireHoldingEntry>]
  let nextCursor: String?
}

struct WireRevealResult: Decodable {
  let outcome: String
  let holding: WireHolding
  let nextRevealAt: Date?

  func model() throws -> RevealResult {
    guard let holding = holding.model else {
      throw VeraHubError(
        .unexpected,
        "VeraHub revealed a \(holding.kind) holding, which this SDK version cannot show.")
    }
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

extension RevealUnavailableReason {
  /// The reason a reveal's problem stands for, or `nil` for a problem that is an error.
  init?(_ problem: Problem) {
    switch problem.code {
    case "sold-out": self = .soldOut
    case "quota-reached": self = .quotaReached
    case "not-available": self = .notAvailable
    case "user-limit-reached": self = .limitReached(until: problem.nextRevealAt)
    default:
      guard problem.status == 409 else { return nil }
      self = .other
    }
  }
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
