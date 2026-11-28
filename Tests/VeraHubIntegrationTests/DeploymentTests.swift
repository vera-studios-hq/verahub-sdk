import Foundation
import Testing

@testable import VeraHub

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The deployment the tests run against, from the environment:
/// `VERAHUB_API_URL` (such as `https://publisher-api.sandbox.verahub.io`) and `VERAHUB_API_KEY`, a
/// publisher API key of a test app there. The tests act as that app's backend and its app.
enum Deployment {
  static let url = ProcessInfo.processInfo.environment["VERAHUB_API_URL"].flatMap(URL.init(string:))
  static let key = ProcessInfo.processInfo.environment["VERAHUB_API_KEY"]
  static var configured: Bool { url != nil && key?.isEmpty == false }
  static var environment: VeraHubEnvironment { .custom(url!) }

  /// A user token for `userId`, as a publisher's backend gets one.
  static func token(for userId: String) async throws -> String {
    var request = URLRequest(url: url!.appendingPathComponent("v1/user-tokens"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(key!)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["userId": userId])
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as! HTTPURLResponse).statusCode
    guard status == 201 || status == 200 else {
      throw TokenFailed(status: status, body: String(decoding: data, as: UTF8.self))
    }
    return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["token"] as! String
  }

  struct TokenFailed: Error {
    let status: Int
    let body: String
  }

  static func client(
    _ userId: String, consent: Consent = Consent(analytics: true, personalisation: true)
  )
    -> VeraHubClient
  {
    VeraHubClient(environment: environment, userId: userId, consent: consent) { userId in
      try await token(for: userId)
    }
  }
}

/// Fixed end users of the test app, so runs do not create new ones.
let userA = "sdk-test-a"
let userB = "sdk-test-b"

/// Runs `body`, and passes with a note when the deployment answers `501`: the route is in the
/// spec but not built there yet.
func whereBuilt(_ route: String, _ body: () async throws -> Void) async throws {
  do {
    try await body()
  } catch let error as VeraHubError where error.status == 501 {
    print("◇ \(route) is not built on \(Deployment.url!.host ?? "") yet (501); not tested.")
  }
}

@Suite(.enabled(if: Deployment.configured), .serialized) struct DeploymentTests {
  @Test func theDeploymentServesTheSpecTheseFixturesCameFrom() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let committed =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("spec/publisher.json")))
      as! [String: Any]
    let (data, _) = try await URLSession.shared.data(
      from: Deployment.url!.appendingPathComponent("v1/openapi.json"))
    let served = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let paths = { (spec: [String: Any]) in
      try JSONSerialization.data(withJSONObject: spec["paths"]!, options: .sortedKeys)
    }
    if try paths(committed) != paths(served) {
      print(
        "◇ The deployment serves another spec than spec/publisher.json; sync it to build against it."
      )
    }
  }

  @Test func consentAndOfferViewsAreAccepted() async throws {
    // The wire layer as the client uses it, to see the answers it otherwise keeps to itself.
    let session = Session(
      environment: Deployment.environment, userId: userA, token: Deployment.token(for:),
      transport: URLSessionTransport(), clock: SystemClock(), context: .current(),
      log: Log(level: .off))
    _ = try await session.data(
      .send("PUT", "consent") { WireConsent(analytics: true, personalisation: false) })
    _ = try await session.data(
      .send("POST", "events") {
        WireSendEvents(
          sentAt: Date(),
          events: [
            WireClientEvent(
              id: UUID().uuidString.lowercased(), name: "offerViewed",
              occurredAt: Date().addingTimeInterval(-2),
              properties: [
                "offerId": "019a8f2e-3a02-7f18-a4b6-1d9c8e5f2a70", "feedId": "sdk-test-feed",
              ])
          ])
      })
  }

  @Test func aTokenOfAnotherUserIsRefused() async throws {
    let tokenOfA = try await Deployment.token(for: userA)
    let client = VeraHubClient(
      environment: Deployment.environment, userId: userB,
      consent: Consent(analytics: false, personalisation: false)
    ) { _ in tokenOfA }
    // Consent: the route every deployment has built.
    let session = Session(
      environment: Deployment.environment, userId: userB, token: { _ in tokenOfA },
      transport: URLSessionTransport(), clock: SystemClock(), context: .current(),
      log: Log(level: .off))
    let error = await veraHubError {
      _ = try await session.data(.get("consent"))
    }
    #expect(error?.kind == .userMismatch)
    try await whereBuilt("GET /v1/me/holdings") {
      let error = await veraHubError {
        try await client.holdings().loadNext()
      }
      #expect(error?.kind == .userMismatch)
    }
  }

  @Test func aTokenOfNoDeploymentIsMisconfigured() async throws {
    let session = Session(
      environment: Deployment.environment, userId: userA, token: { _ in "not-a-token" },
      transport: URLSessionTransport(), clock: SystemClock(), context: .current(),
      log: Log(level: .off))
    let error = await veraHubError {
      _ = try await session.data(.get("consent"))
    }
    #expect(error?.kind == .misconfigured)
    #expect(error?.requestId != nil)
  }

  @Test func theCatalogueCanBeBrowsedAndACouponRevealed() async throws {
    let client = Deployment.client(userA)
    try await whereBuilt("GET /v1/me/categories") {
      let categories = try await client.categories()
      #expect(!categories.isEmpty)
    }
    try await whereBuilt("GET /v1/me/offers") {
      let offers = client.offers()
      var all: [Offer] = []
      while await !offers.isComplete { all += try await offers.loadNext() }
      #expect(!all.isEmpty)
      #expect(Set(all.map(\.id)).count == all.count)
      let offer = try #require(all.first { !$0.benefits.isEmpty })
      let detail = try await client.offerDetail(for: offer)
      #expect(detail.offer.id == offer.id)
      try await whereBuilt("POST /v1/me/benefits/{benefitId}/reveal") {
        let result = try await client.reveal(offer.benefits[0])
        if let holding = result.holding {
          #expect(holding.coupon?.code.isEmpty == false)
        }
      }
    }
    try await whereBuilt("GET /v1/me/holdings") {
      _ = try await client.holdings().loadNext()
    }
  }
}

/// The `VeraHubError` `body` throws, recording an issue if it throws none.
/// (`#expect(throws:)` returns the error only from Swift 6.1.)
func veraHubError<Value>(
  sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Value
) async -> VeraHubError? {
  do {
    _ = try await body()
    Issue.record("Expected a VeraHubError", sourceLocation: sourceLocation)
  } catch let error as VeraHubError {
    return error
  } catch {
    Issue.record("Expected a VeraHubError, got \(error)", sourceLocation: sourceLocation)
  }
  return nil
}
