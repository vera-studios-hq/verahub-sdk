import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One request of the publisher API, relative to the environment's address.
struct Endpoint: Sendable {
  var method: String
  var path: [String]
  var query: [URLQueryItem] = []
  /// The JSON body, written anew for each attempt, so a time in it is the attempt's.
  var body: (@Sendable () throws -> Data)?
  /// Asked before each attempt; when it says no, the request is abandoned with ``Abandoned``.
  var precondition: (@Sendable () -> Bool)?

  static func get(_ path: String..., query: [URLQueryItem] = []) -> Endpoint {
    Endpoint(method: "GET", path: path, query: query)
  }

  static func send<Body: Encodable & Sendable>(
    _ method: String, _ path: String..., body: @escaping @Sendable () -> Body
  ) -> Endpoint {
    Endpoint(method: method, path: path) { try JSON.encoder.encode(body()) }
  }

  static func post(_ path: String...) -> Endpoint {
    Endpoint(method: "POST", path: path)
  }

  /// This request, sent only while `condition` holds at each attempt.
  func only(if condition: @escaping @Sendable () -> Bool) -> Endpoint {
    var endpoint = self
    endpoint.precondition = condition
    return endpoint
  }

  /// The benefit kinds this SDK version can show; every request that returns benefits names them.
  static var benefitKinds: [URLQueryItem] {
    BenefitKind.supported.map { URLQueryItem(name: "benefitKinds", value: $0.rawValue) }
  }
}

/// Thrown when a request is not sent, or not sent again, because its precondition no longer holds
/// or the client was signed out. It is neither a failure nor a problem of the API.
struct Abandoned: Error {}

/// A problem the API answered with, after the session's retries.
struct Problem: Error, Sendable {
  let status: Int
  let code: String?
  let detail: String?
  let requestId: String?
  let nextRevealAt: Date?
  let retryAfter: Double?
}

/// Sends requests for one end user: the token, the two VeraHub headers, retries of transient
/// failures, one refresh after `user-token-expired`, and the problems the API answers with.
final class Session: Sendable {
  let userId: String
  let log: Log
  let clock: any SDKClock
  private let baseURL: URL
  private let transport: any Transport
  private let context: ClientContext
  private let tokens: TokenProvider
  private let ended = Locked(false)

  /// Attempts per request when the API or the connection fails in a way that can pass.
  static let attempts = 3
  /// The longest `Retry-After` the session waits for itself; a longer one fails the request.
  static let longestWait = 10.0

  init(
    environment: VeraHubEnvironment, userId: String, token: @escaping TokenProvider.Callback,
    transport: any Transport, clock: any SDKClock, context: ClientContext, log: Log
  ) {
    baseURL = environment.baseURL
    self.userId = userId
    self.transport = transport
    self.clock = clock
    self.context = context
    self.log = log
    tokens = TokenProvider(userId: userId, callback: token)
  }

  var isEnded: Bool { ended.withLock { $0 } }

  /// Refuses every request from now on, also those still waiting for their answer.
  func markEnded() {
    ended.withLock { $0 = true }
  }

  func end() async {
    markEnded()
    await tokens.dropAll()
  }

  /// The decoded answer, or the ``VeraHubError`` for a problem.
  func decode<Answer: Decodable>(_ type: Answer.Type, _ endpoint: Endpoint) async throws -> Answer {
    try decoded(Answer.self, from: try await data(endpoint), endpoint)
  }

  /// The decoded answer, or the problem the API answered with, for a call that handles some
  /// problems itself; other failures throw a ``VeraHubError``.
  func decodeOrProblem<Answer: Decodable>(_ type: Answer.Type, _ endpoint: Endpoint) async throws
    -> Result<Answer, Problem>
  {
    do {
      return .success(try decoded(Answer.self, from: try await dataOrProblem(endpoint), endpoint))
    } catch let problem as Problem {
      return .failure(problem)
    }
  }

  /// The answer's body, or the ``VeraHubError`` for a problem.
  func data(_ endpoint: Endpoint) async throws -> Data {
    do {
      return try await dataOrProblem(endpoint)
    } catch let problem as Problem {
      throw error(for: problem)
    }
  }

  private func decoded<Answer: Decodable>(
    _ type: Answer.Type, from data: Data, _ endpoint: Endpoint
  )
    throws -> Answer
  {
    do {
      return try JSON.decoder.decode(Answer.self, from: data)
    } catch {
      log.error("\(endpoint.method) \(endpoint.path.first ?? ""): cannot read the answer: \(error)")
      throw VeraHubError(
        .unexpected, "VeraHub's answer does not match what this SDK version expects: \(error).")
    }
  }

  /// The answer's body; throws a ``Problem`` the API answered with, a ``VeraHubError``, or
  /// ``Abandoned``.
  func dataOrProblem(_ endpoint: Endpoint) async throws -> Data {
    guard Self.isValidUserId(userId) else {
      throw VeraHubError(
        .misconfigured,
        "The userId must be 1 to 128 letters, digits, '.', '_', '~', or '-', starting with a letter or digit."
      )
    }
    try checkNotEnded()
    var token = try await tokens.current()
    var result = await send(endpoint, token: token)
    if case .failure(let problem as Problem) = result, problem.code == "user-token-expired" {
      log.info("The user token expired; asking the token callback for a new one.")
      try checkNotEnded()
      token = try await tokens.refresh(replacing: token)
      result = await send(endpoint, token: token)
    }
    // A signed-out client shows nothing, also when its answer arrives later.
    try checkNotEnded()
    if case .failure(let problem as Problem) = result,
      ["user-token-expired", "user-token-invalid", "user-mismatch"].contains(problem.code)
    {
      await tokens.drop(token)
    }
    return try result.get()
  }

  private func checkNotEnded() throws {
    if isEnded {
      throw VeraHubError(.signedOut, "This client was signed out; create a new one for the user.")
    }
  }

  private func send(_ endpoint: Endpoint, token: String) async -> Result<Data, any Error> {
    var request = URLRequest(url: url(endpoint))
    request.httpMethod = endpoint.method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if endpoint.body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(userId, forHTTPHeaderField: "VeraHub-Expected-User")
    request.setValue(context.header, forHTTPHeaderField: "VeraHub-Client")
    let name = "\(endpoint.method) /\(endpoint.path.first.map { "v1/me/\($0)" } ?? "v1/me")"

    var attempt = 1
    while true {
      guard !isEnded, endpoint.precondition?() ?? true else {
        log.debug("\(name): not sent; it no longer applies.")
        return .failure(Abandoned())
      }
      let wait: Double
      do {
        request.httpBody = try endpoint.body?()
        let (data, response) = try await transport.send(request)
        let requestId = response.value(forHTTPHeaderField: "X-Request-Id")
        if (200..<300).contains(response.statusCode) {
          log.info("\(name): \(response.statusCode) [request \(requestId ?? "-")]")
          return .success(data)
        }
        let problem = Self.problem(data: data, response: response)
        log.info(
          "\(name): \(problem.status) \(problem.code ?? "") [request \(problem.requestId ?? "-")]")
        guard [429, 500, 502, 503, 504].contains(problem.status), attempt < Self.attempts else {
          return .failure(problem)
        }
        if let retryAfter = problem.retryAfter, retryAfter > Self.longestWait {
          return .failure(problem)
        }
        wait = problem.retryAfter ?? Self.backoff(attempt)
      } catch {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
          return .failure(CancellationError())
        }
        let urlError = error as? URLError
        log.info("\(name): \(urlError.map { "URLError \($0.code.rawValue)" } ?? "\(error)")")
        guard let urlError, [.timedOut, .networkConnectionLost].contains(urlError.code),
          attempt < Self.attempts
        else {
          return .failure(Self.connectionError(error))
        }
        wait = Self.backoff(attempt)
      }
      do {
        try await clock.sleep(seconds: wait)
      } catch {
        return .failure(CancellationError())
      }
      attempt += 1
    }
  }

  private func url(_ endpoint: Endpoint) -> URL {
    let base = baseURL.appendingPathComponent("v1").appendingPathComponent("me")
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return base
    }
    // Each segment is one path segment: a `/`, `?`, or `%` in an id is encoded, never a separator.
    components.percentEncodedPath += endpoint.path.map {
      "/" + ($0.addingPercentEncoding(withAllowedCharacters: Self.segmentCharacters) ?? "")
    }.joined()
    if !endpoint.query.isEmpty {
      components.queryItems = endpoint.query
      // `+` would read as a space in a query value.
      components.percentEncodedQuery = components.percentEncodedQuery?
        .replacingOccurrences(of: "+", with: "%2B")
    }
    return components.url ?? base
  }

  /// The characters a path segment keeps unencoded (RFC 3986 `pchar` without `%`).
  private static let segmentCharacters: CharacterSet = {
    var characters = CharacterSet.urlPathAllowed
    characters.remove(charactersIn: "/%;")
    return characters
  }()

  static func backoff(_ attempt: Int) -> Double { attempt == 1 ? 0.5 : 1.5 }

  /// An offer or benefit id as a request names it: 1 to 64 characters and not `.` or `..`, so
  /// an id from a deep link reaches no other route. Any other is an offer that is not listed.
  static func pathId(_ id: String) throws -> String {
    guard (1...64).contains(id.count), id != ".", id != ".." else {
      throw VeraHubError(.offerNotFound, "No offer or benefit has the id \"\(id.prefix(64))\".")
    }
    return id
  }

  static func isValidUserId(_ userId: String) -> Bool {
    let scalars = Array(userId.unicodeScalars)
    guard (1...128).contains(scalars.count) else { return false }
    func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
      ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
    return isAlphanumeric(scalars[0])
      && scalars.allSatisfy { isAlphanumeric($0) || ".-_~".unicodeScalars.contains($0) }
  }

  private static func problem(data: Data, response: HTTPURLResponse) -> Problem {
    let wire = try? JSON.decoder.decode(WireProblem.self, from: data)
    return Problem(
      status: response.statusCode, code: wire?.code, detail: wire?.detail,
      requestId: wire?.requestId ?? response.value(forHTTPHeaderField: "X-Request-Id"),
      nextRevealAt: wire?.nextRevealAt,
      retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(retryAfter))
  }

  /// `Retry-After` in seconds, from either of its forms.
  private static func retryAfter(_ value: String) -> Double? {
    if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) { return max(0, seconds) }
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "GMT")
    format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return format.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
  }

  private static func connectionError(_ error: any Error) -> VeraHubError {
    let offline: [URLError.Code] = [
      .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
      .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
    ]
    if let urlError = error as? URLError, offline.contains(urlError.code) {
      return VeraHubError(
        .noConnection, "VeraHub cannot be reached: \(urlError.localizedDescription)")
    }
    return VeraHubError(.unexpected, "The request failed: \(error.localizedDescription)")
  }

  /// The error a call throws for a problem it does not handle itself.
  func error(for problem: Problem) -> VeraHubError {
    let status = problem.status
    func make(_ kind: VeraHubError.Kind, _ message: String) -> VeraHubError {
      VeraHubError(
        kind, message, requestId: problem.requestId, status: status, problemCode: problem.code)
    }
    switch problem.code {
    case "user-token-expired":
      return make(
        .misconfigured, "The token callback returned an expired token; it must return a fresh one.")
    case "user-token-invalid":
      return make(
        .misconfigured,
        "VeraHub refused the user token. Tokens must come from POST /v1/user-tokens of the client's environment."
      )
    case "user-not-found":
      return make(.userDeleted, "The user no longer exists at VeraHub: your backend deleted them.")
    case "user-mismatch":
      return make(
        .userMismatch,
        "The token callback returned a token of another user than \(userId); nothing was shown.")
    case "sdk-unsupported":
      return make(.sdkUnsupported, "This SDK version is no longer served; update the VeraHub SDK.")
    case "offer-not-found", "benefit-not-found":
      return make(.offerNotFound, "The offer or benefit is no longer listed for the user.")
    default:
      if status == 429 || status >= 500 {
        return make(.serviceUnavailable, "VeraHub cannot answer right now; try again later.")
      }
      return make(
        .unexpected,
        "VeraHub answered \(status)\(problem.code.map { " \($0)" } ?? ""): \(problem.detail ?? "no detail")."
      )
    }
  }
}
