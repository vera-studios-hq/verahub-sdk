import Foundation
import Testing

@testable import VeraHub

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The shared fixture at `fixtures/<name>.json`.
func fixture(_ name: String) -> Data {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return try! Data(contentsOf: root.appendingPathComponent("fixtures/\(name).json"))
}

func json(_ data: Data) -> Any { try! JSONSerialization.jsonObject(with: data) }

/// A request as the fake API received it.
struct Received: Sendable {
  let method: String
  let path: String
  let query: [String: [String]]
  let headers: Headers
  let body: Data?

  var token: String? { headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) } }
  var bodyJSON: [String: Any] { json(body ?? Data("{}".utf8)) as! [String: Any] }
}

/// Request headers, by case-insensitive name.
struct Headers: Sendable {
  private let values: [String: String]
  init(_ values: [String: String]) {
    self.values = Dictionary(values.map { ($0.key.lowercased(), $0.value) }) { $1 }
  }
  subscript(_ name: String) -> String? { values[name.lowercased()] }
}

/// An answer of the fake API.
struct Answer: Sendable {
  var status: Int
  var body: Data
  var headers: [String: String] = [:]

  static func ok(_ fixtureName: String) -> Answer {
    Answer(status: 200, body: fixture(fixtureName))
  }
  static func ok(json: String) -> Answer { Answer(status: 200, body: Data(json.utf8)) }
  static let noContent = Answer(status: 204, body: Data())

  /// The problem fixture of `code`, at its status.
  static func problem(_ code: String, headers: [String: String] = [:]) -> Answer {
    let body = fixture("problems/\(code)")
    let status = (json(body) as! [String: Any])["status"] as! Int
    return Answer(status: status, body: body, headers: headers)
  }
}

/// The publisher API at its boundary: it records every request and answers through `handler`,
/// by default consent and events with success and everything else with `501`.
final class FakeAPI: Transport, @unchecked Sendable {
  typealias Handler = @Sendable (Received) async throws -> Answer

  private let lock = NSLock()
  private var _received: [Received] = []
  private var _handler: Handler

  init(_ handler: Handler? = nil) {
    _handler = handler ?? FakeAPI.defaults
  }

  static let defaults: Handler = { request in
    switch (request.method, request.path) {
    case ("PUT", "/v1/me/consent"): .ok("responses/replaceConsent.200")
    case ("POST", "/v1/me/events"): .noContent
    default: Answer(status: 501, body: Data())
    }
  }

  var received: [Received] { lock.locked { _received } }

  func received(_ method: String, _ path: String) -> [Received] {
    received.filter { $0.method == method && $0.path == path }
  }

  /// Answers `method path` with `answer`, and everything else as before.
  func on(_ method: String, _ path: String, _ answer: @escaping Handler) {
    lock.locked {
      let previous = _handler
      _handler = { request in
        request.method == method && request.path == path
          ? try await answer(request) : try await previous(request)
      }
    }
  }

  func on(_ method: String, _ path: String, _ answer: Answer) {
    on(method, path) { _ in answer }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    var query: [String: [String]] = [:]
    for item in components.queryItems ?? [] {
      query[item.name, default: []].append(item.value ?? "")
    }
    let received = Received(
      method: request.httpMethod ?? "GET", path: components.path, query: query,
      headers: Headers(request.allHTTPHeaderFields ?? [:]), body: request.httpBody)
    let handler = lock.locked {
      _received.append(received)
      return _handler
    }
    let answer = try await handler(received)
    var headers = answer.headers
    headers["X-Request-Id"] = headers["X-Request-Id"] ?? "req-\(self.received.count)"
    let response = HTTPURLResponse(
      url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
      headerFields: headers)!
    return (answer.body, response)
  }
}

/// A clock whose time moves only when a test advances it.
final class ManualClock: SDKClock, @unchecked Sendable {
  private struct Sleeper {
    let id: UUID
    let deadline: Date
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_795_000_000)
  private var sleepers: [Sleeper] = []
  private var cancelled: Set<UUID> = []

  func now() -> Date { lock.locked { current } }

  var waiting: Int { lock.locked { sleepers.count } }

  func sleep(seconds: Double) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let resumeNow: (any Error)?? = lock.locked {
          if cancelled.remove(id) != nil { return .some(CancellationError()) }
          if seconds <= 0 { return .some(nil) }
          sleepers.append(Sleeper(id: id, deadline: current + seconds, continuation: continuation))
          return .none
        }
        switch resumeNow {
        case .some(.some(let error)): continuation.resume(throwing: error)
        case .some(.none): continuation.resume()
        case .none: break
        }
      }
    } onCancel: {
      let sleeper: Sleeper? = lock.locked {
        if let index = sleepers.firstIndex(where: { $0.id == id }) {
          return sleepers.remove(at: index)
        }
        cancelled.insert(id)
        return nil
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Moves time on and wakes every sleeper whose time has come.
  func advance(by seconds: Double) {
    let due = lock.locked {
      current += seconds
      let due = sleepers.filter { $0.deadline <= current }
      sleepers.removeAll { $0.deadline <= current }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}

/// Waits until `condition` holds, for tasks the client runs on its own.
func eventually(
  _ description: String = "condition", timeout: Double = 3,
  sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool
) async rethrows {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if try await condition() { return }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
}

/// Lets the client's own tasks run, to show that something does not happen.
func settle() async {
  try? await Task.sleep(nanoseconds: 100_000_000)
}

/// Counts calls of a token callback and answers with the tokens it is given, in turn.
final class TokenCallback: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String]
  private(set) var calls = 0

  init(_ tokens: String...) { self.tokens = tokens }

  var callback: @Sendable (String) async throws -> String {
    { [self] _ in
      lock.locked {
        calls += 1
        return tokens.count > 1 ? tokens.removeFirst() : tokens[0]
      }
    }
  }
}

func makeClient(
  _ api: FakeAPI, userId: String = "u-1",
  consent: Consent = Consent(analytics: true, personalisation: true),
  clock: ManualClock = ManualClock(), token: TokenCallback = TokenCallback("t-1")
) -> VeraHubClient {
  VeraHubClient(
    userId: userId, consent: consent, token: token.callback, transport: api, clock: clock)
}

extension NSLock {
  /// `withLock`, which needs iOS 16.
  func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
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
