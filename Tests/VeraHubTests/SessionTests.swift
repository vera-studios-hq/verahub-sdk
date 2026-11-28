import Foundation
import Testing

@testable import VeraHub

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The API as it treats tokens: each token belongs to one user, and `VeraHub-Expected-User`
/// naming someone else is refused. Each user's holdings are their own.
func usersAPI(tokens: [String: String], expired: Set<String> = []) -> FakeAPI {
  let api = FakeAPI()
  api.on("GET", "/v1/me/holdings") { request in
    guard let token = request.token, let owner = tokens[token] else {
      return .problem("user-token-invalid")
    }
    if expired.contains(token) { return .problem("user-token-expired") }
    if let expected = request.headers["VeraHub-Expected-User"], expected != owner {
      return .problem("user-mismatch")
    }
    return .ok(json: holdingsPage(code: "CODE-OF-\(owner)"))
  }
  return api
}

func holdingsPage(code: String) -> String {
  lastPage("responses/listHoldings.200").replacingOccurrences(of: "ALPEN-7K4Q-92XD", with: code)
}

@Suite struct SessionTests {
  @Test func aSecondUserNeverSeesTheFirstUsersHoldings() async throws {
    let api = usersAPI(tokens: ["token-a": "user-a", "token-b": "user-b"])
    let first = makeClient(api, userId: "user-a", token: TokenCallback("token-a"))
    #expect(try await first.holdings().loadNext().first?.holding.coupon?.code == "CODE-OF-user-a")
    first.signOut()

    // The second user's client gets a callback that still returns the first user's token.
    let second = makeClient(api, userId: "user-b", token: TokenCallback("token-a", "token-b"))
    let error = await veraHubError { try await second.holdings().loadNext() }
    #expect(error?.kind == .userMismatch)

    // Once the callback returns the right token, the second user sees their own.
    #expect(try await second.holdings().loadNext().first?.holding.coupon?.code == "CODE-OF-user-b")
  }

  @Test func aSignedOutClientShowsNothingAndRefusesCalls() async throws {
    let api = usersAPI(tokens: ["token-a": "user-a"])
    let gate = Gate()
    api.on("GET", "/v1/me/categories") { _ in
      await gate.wait()
      return .ok("responses/listCategories.200")
    }
    let client = makeClient(api, userId: "user-a", token: TokenCallback("token-a"))
    let pending = Task { try await client.categories() }
    await eventually("the request to be sent") { !api.received("GET", "/v1/me/categories").isEmpty }

    client.signOut()
    await gate.open()

    let late = await veraHubError { try await pending.value }
    #expect(late?.kind == .signedOut)
    let after = await veraHubError { try await client.holdings().loadNext() }
    #expect(after?.kind == .signedOut)
  }

  @Test func concurrentFirstRequestsAskTheCallbackOnce() async throws {
    let api = usersAPI(tokens: ["token-a": "user-a"])
    let token = TokenCallback("token-a")
    let client = makeClient(api, userId: "user-a", token: token)

    async let a = client.holdings().loadNext()
    async let b = client.holdings().loadNext()
    async let c = client.holdings().loadNext()
    _ = try await [a, b, c]

    #expect(token.calls == 1)
  }

  @Test func anExpiredTokenIsRefreshedOnceAndTheRequestRetried() async throws {
    let api = usersAPI(tokens: ["old": "user-a", "new": "user-a"], expired: ["old"])
    let token = TokenCallback("old", "new")
    let client = makeClient(api, userId: "user-a", token: token)

    #expect(try await client.holdings().loadNext().count == 1)
    #expect(token.calls == 2)
    #expect(api.received("GET", "/v1/me/holdings").map(\.token) == ["old", "new"])
  }

  @Test func concurrentRequestsShareOneRefresh() async throws {
    let api = usersAPI(tokens: ["old": "user-a", "new": "user-a"], expired: ["old"])
    let token = TokenCallback("old", "new")
    let client = makeClient(api, userId: "user-a", token: token)
    _ = try await client.holdings().loadNext()

    async let a = client.holdings().loadNext()
    async let b = client.holdings().loadNext()
    _ = try await [a, b]
    #expect(token.calls == 2)
  }

  @Test func aCallbackThatKeepsReturningExpiredTokensFailsAfterOneRefresh() async throws {
    let api = usersAPI(tokens: ["old": "user-a"], expired: ["old"])
    let token = TokenCallback("old")
    let error = await veraHubError {
      try await makeClient(api, userId: "user-a", token: token).holdings().loadNext()
    }
    #expect(error?.kind == .misconfigured)
    #expect(error?.problemCode == "user-token-expired")
    #expect(api.received("GET", "/v1/me/holdings").count == 2)
  }

  @Test func aCallbackErrorIsRethrownUnchanged() async throws {
    struct BackendDown: Error {}
    let client = VeraHubClient(
      userId: "u-1", consent: Consent(analytics: false, personalisation: false),
      token: { _ in throw BackendDown() }, transport: FakeAPI(), clock: ManualClock())
    await #expect(throws: BackendDown.self) { try await client.categories() }
  }

  @Test func anInvalidUserIdFailsWithoutARequest() async throws {
    let api = FakeAPI()
    let error = await veraHubError {
      try await makeClient(api, userId: "-starts-with-a-dash").categories()
    }
    #expect(error?.kind == .misconfigured)
    #expect(api.received("GET", "/v1/me/categories").isEmpty)
  }

  @Test(arguments: [
    ("user-token-invalid", VeraHubError.Kind.misconfigured),
    ("user-not-found", .userDeleted),
    ("sdk-unsupported", .sdkUnsupported),
    ("offer-not-found", .offerNotFound),
    ("request-invalid", .unexpected),
    ("cursor-invalid", .unexpected),
    ("internal-server-error", .serviceUnavailable),
    ("temporarily-unavailable", .serviceUnavailable),
    ("rate-limited", .serviceUnavailable),
  ])
  func problemFixturesBecomeTheirErrors(code: String, kind: VeraHubError.Kind) async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/offers/o-1", .problem(code, headers: ["X-Request-Id": "req-x"]))
    let clock = ManualClock()
    let client = makeClient(api, clock: clock)
    let call = Task { try await client.offerDetail(offerId: "o-1") }
    // Transient problems are retried; let the retries' waits pass.
    let retrying = Task {
      while !Task.isCancelled {
        clock.advance(by: 2)
        try? await Task.sleep(nanoseconds: 2_000_000)
      }
    }
    defer { retrying.cancel() }
    let error = await veraHubError { try await call.value }
    #expect(error?.kind == kind)
    // A plain HTTP error, such as `internal-server-error`, carries no code.
    #expect(
      error?.problemCode == (json(fixture("problems/\(code)")) as! [String: Any])["code"] as? String
    )
    #expect(error?.requestId == "req-x")
  }

  @Test func aTransientProblemIsRetriedAfterItsRetryAfter() async throws {
    let api = FakeAPI()
    let answers = Locked([
      Answer.problem("rate-limited", headers: ["Retry-After": "2"]),
      .ok("responses/listCategories.200"),
    ])
    api.on("GET", "/v1/me/categories") { _ in answers.withLock { $0.removeFirst() } }
    let clock = ManualClock()
    let call = Task { try await makeClient(api, clock: clock).categories() }
    await eventually("the first attempt") {
      api.received("GET", "/v1/me/categories").count == 1 && clock.waiting >= 2
    }

    clock.advance(by: 1.9)
    await settle()
    #expect(api.received("GET", "/v1/me/categories").count == 1)
    clock.advance(by: 0.1)

    #expect(try await call.value.count > 0)
    #expect(api.received("GET", "/v1/me/categories").count == 2)
  }

  @Test func aLongRetryAfterFailsAtOnce() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/categories", .problem("rate-limited", headers: ["Retry-After": "120"]))
    let error = await veraHubError { try await makeClient(api).categories() }
    #expect(error?.kind == .serviceUnavailable)
    #expect(api.received("GET", "/v1/me/categories").count == 1)
  }

  @Test func withoutAConnectionTheCallFailsWithNoConnection() async throws {
    let api = FakeAPI()
    api.on("GET", "/v1/me/categories") { _ in throw URLError(.notConnectedToInternet) }
    let error = await veraHubError { try await makeClient(api).categories() }
    #expect(error?.kind == .noConnection)
  }
}

@Suite struct RevealTests {
  @Test func aRevealReadsTheRevealFixture() async throws {
    let api = FakeAPI()
    api.on("POST", "/v1/me/benefits/b-1/reveal", .ok("responses/revealBenefit.200"))
    let result = try await makeClient(api).reveal(benefitId: "b-1")
    guard case .revealed(let holding, let nextRevealAt) = result else {
      Issue.record("expected revealed, got \(result)")
      return
    }
    #expect(holding.coupon?.code == "ALPEN-7K4Q-92XD")
    #expect(holding.expiresAt == date("2027-03-31T21:59:59.000Z"))
    #expect(holding.clickOut?.url.host == "go.verahub.de")
    #expect(nextRevealAt == date("2026-12-23T09:30:00.000Z"))
  }

  @Test(
    arguments: [
      ("already-held", "2026-12-23T09:30:00.000Z", "alreadyHeld"),
      ("cooldown", "2026-12-23T09:30:00.000Z", "cooldown"),
      ("cooldown", nil, "alreadyHeld"),
      ("a-later-outcome", nil, "revealed"),
    ] as [(String, String?, String)])
  func revealOutcomes(outcome: String, nextRevealAt: String?, expected: String) async throws {
    var body = json(fixture("responses/revealBenefit.200")) as! [String: Any]
    body["outcome"] = outcome
    body["nextRevealAt"] = nextRevealAt
    let api = FakeAPI()
    api.on(
      "POST", "/v1/me/benefits/b-1/reveal",
      Answer(status: 200, body: try JSONSerialization.data(withJSONObject: body)))
    let result = try await makeClient(api).reveal(benefitId: "b-1")
    let name =
      switch result {
      case .revealed: "revealed"
      case .alreadyHeld: "alreadyHeld"
      case .cooldown(_, let until):
        until == date(nextRevealAt!) ? "cooldown" : "cooldown with the wrong date"
      case .unavailable: "unavailable"
      }
    #expect(name == expected)
    #expect(result.holding?.coupon?.code == "ALPEN-7K4Q-92XD")
  }

  @Test(arguments: [
    ("sold-out", RevealUnavailableReason.soldOut),
    ("quota-reached", .quotaReached),
    ("not-available", .notAvailable),
    ("user-limit-reached", .limitReached(until: date("2026-11-24T00:00:00.000Z"))),
  ])
  func problemsThatGiveNoHoldingAreResults(code: String, reason: RevealUnavailableReason)
    async throws
  {
    let api = FakeAPI()
    api.on("POST", "/v1/me/benefits/b-1/reveal", .problem(code))
    #expect(try await makeClient(api).reveal(benefitId: "b-1") == .unavailable(reason))
  }

  @Test func anUnknownConflictIsAnUnavailableResult() async throws {
    let api = FakeAPI()
    api.on(
      "POST", "/v1/me/benefits/b-1/reveal",
      Answer(
        status: 409,
        body: Data(
          #"{"type":"/problems/later","code":"later","title":"Conflict","status":409}"#.utf8)))
    #expect(try await makeClient(api).reveal(benefitId: "b-1") == .unavailable(.other))
  }

  @Test func anUnknownBenefitThrowsOfferNotFound() async throws {
    let api = FakeAPI()
    api.on("POST", "/v1/me/benefits/b-1/reveal", .problem("benefit-not-found"))
    let error = await veraHubError {
      try await makeClient(api).reveal(benefitId: "b-1")
    }
    #expect(error?.kind == .offerNotFound)
  }
}

/// Holds a fake answer back until a test opens it.
actor Gate {
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func open() {
    isOpen = true
    for continuation in waiting { continuation.resume() }
    waiting.removeAll()
  }
}
