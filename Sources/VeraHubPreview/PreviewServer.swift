import Foundation
import VeraHub

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Answers the client's requests as the publisher API would, from the fixtures, and keeps what
/// the user reveals in memory.
final class PreviewServer: Transport, @unchecked Sendable {
  typealias Object = [String: Any]

  private let reveal: VeraHubPreview.RevealBehaviour
  private let latency: Double
  private let lock = NSLock()
  /// The user's holding entries, newest first, as the holdings list carries them.
  private var holdings: [Object]
  private var views: [VeraHubPreview.SentView] = []

  init(reveal: VeraHubPreview.RevealBehaviour, latency: Double) {
    self.reveal = reveal
    self.latency = latency
    holdings = (Self.fixture("responses/listHoldings.200")["items"] as! [Object]).map {
      Self.withPreviewCode($0, at: ["holding"])
    }
  }

  var sentViews: [VeraHubPreview.SentView] { lock.locked { views } }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
    let url = request.url!
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let path = components.path.split(separator: "/").map(String.init)
    let query = components.queryItems ?? []
    let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? Object }
    let (status, answer) = lock.locked {
      route(request.httpMethod ?? "GET", Array(path.dropFirst(2)), query: query, body: body)
    }
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": status < 400 ? "application/json" : "application/problem+json",
        "X-Request-Id": "preview-\(UUID().uuidString.prefix(8).lowercased())",
      ])!
    let data = try answer.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
    return (data, response)
  }

  /// The answer to `method /v1/me/<path>`; called with the lock held.
  private func route(_ method: String, _ path: [String], query: [URLQueryItem], body: Object?)
    -> (Int, Object?)
  {
    // `offers/<offerId>` and `benefits/<benefitId>/reveal` match as `offers/*` and so on.
    let id = path.count > 1 ? path[1] : ""
    let route =
      "\(method) "
      + (path.count > 1 ? [path[0], "*"] + path.dropFirst(2) : path).joined(separator: "/")
    switch route {
    case "GET offers":
      var list = Self.fixture("responses/listOffers.200")
      var items = list["items"] as! [Object]
      if let category = query.first(where: { $0.name == "category" })?.value {
        items = items.filter { offer in
          (offer["categories"] as! [Object]).contains { $0["key"] as? String == category }
        }
      }
      list["items"] = items
      list["feedId"] = UUID().uuidString.lowercased()
      list.removeValue(forKey: "nextCursor")
      return (200, list)

    case "GET offers/*":
      let offerId = id
      var detail = Self.fixture("responses/getOffer.200")
      guard (detail["offer"] as! Object)["id"] as? String == offerId else {
        return Self.problem("offer-not-found")
      }
      var user = detail["user"] as! Object
      user["holdings"] = holdings.filter {
        ($0["holding"] as! Object)["offerId"] as? String == offerId
      }
      detail["user"] = user
      return (200, detail)

    case "GET categories":
      return (200, Self.fixture("responses/listCategories.200"))

    case "GET holdings":
      return (200, ["items": holdings])

    case "POST benefits/*/reveal":
      return revealBenefit(id)

    case "PUT consent":
      guard let analytics = body?["analytics"] as? Bool,
        let personalisation = body?["personalisation"] as? Bool
      else { return Self.problem("request-invalid") }
      return (
        200,
        [
          "analytics": analytics, "personalisation": personalisation,
          "updatedAt": Self.now(),
        ]
      )

    case "POST events":
      for event in body?["events"] as? [Object] ?? []
      where event["name"] as? String == "offerViewed" {
        let properties = event["properties"] as? [String: String] ?? [:]
        guard let offerId = properties["offerId"], let feedId = properties["feedId"] else {
          continue
        }
        let occurredAt = (event["occurredAt"] as? String).flatMap(Self.date) ?? Date()
        views.append(
          VeraHubPreview.SentView(offerId: offerId, feedId: feedId, occurredAt: occurredAt))
      }
      return (204, nil)

    default:
      return (404, ["type": "about:blank", "title": "Not Found", "status": 404])
    }
  }

  private func revealBenefit(_ benefitId: String) -> (Int, Object?) {
    let detail = Self.fixture("responses/getOffer.200")
    let offer = detail["offer"] as! Object
    let benefits = (detail["user"] as! Object)["benefits"] as! [Object]
    guard let state = benefits.first(where: { $0["benefitId"] as? String == benefitId }) else {
      return Self.problem("benefit-not-found")
    }
    switch reveal {
    case .unavailable(let reason):
      let code: String
      switch reason {
      case .soldOut: code = "sold-out"
      case .quotaReached: code = "quota-reached"
      case .limitReached: code = "user-limit-reached"
      case .notAvailable, .other: code = "not-available"
      }
      return Self.problem(code)
    case .succeed:
      break
    }
    if let held = holdings.first(where: {
      ($0["holding"] as! Object)["benefitId"] as? String == benefitId
    }) {
      var answer: Object = ["outcome": "already-held", "holding": held["holding"]!]
      answer["nextRevealAt"] = state["nextRevealAt"]
      return (200, answer)
    }
    var answer = Self.fixture("responses/revealBenefit.200")
    var holding = answer["holding"] as! Object
    holding["id"] = UUID().uuidString.lowercased()
    holding["benefitId"] = benefitId
    holding["offerId"] = offer["id"]
    holding["heldAt"] = Self.now()
    holding["clickOut"] = state["clickOut"]
    answer["holding"] = holding
    answer["outcome"] = "allocated"
    answer = Self.withPreviewCode(answer, at: ["holding"])
    let benefit = (offer["benefits"] as! [Object]).first { $0["id"] as? String == benefitId } ?? [:]
    var heldBenefit: Object = ["valueText": benefit["valueText"]!, "title": benefit["title"]!]
    heldBenefit["conditions"] = benefit["conditions"]
    let entry: Object = [
      "holding": answer["holding"]!,
      "benefit": heldBenefit,
      "offer": ["id": offer["id"]!, "listed": true, "brand": offer["brand"]!],
    ]
    holdings.insert(entry, at: 0)
    return (200, answer)
  }

  /// `object` with the coupon code at `path` replaced by a visibly fake one.
  private static func withPreviewCode(_ object: Object, at path: [String]) -> Object {
    var object = object
    guard let key = path.first else {
      if var coupon = object["coupon"] as? Object {
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        coupon["code"] = "PREVIEW-" + String((0..<4).map { _ in letters.randomElement()! })
        object["coupon"] = coupon
      }
      return object
    }
    if let inner = object[key] as? Object {
      object[key] = withPreviewCode(inner, at: Array(path.dropFirst()))
    }
    return object
  }

  private static func fixture(_ name: String) -> Object {
    try! JSONSerialization.jsonObject(with: Data(fixtures[name]!.utf8)) as! Object
  }

  private static func problem(_ code: String) -> (Int, Object?) {
    let problem = fixture("problems/\(code)")
    return (problem["status"] as! Int, problem)
  }

  private static let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static func now() -> String { format.format(Date()) }
  private static func date(_ text: String) -> Date? { try? format.parse(text) }
}

extension NSLock {
  /// `withLock`, which needs iOS 16.
  func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}
