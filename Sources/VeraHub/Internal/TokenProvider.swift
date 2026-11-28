/// Holds the user token in memory and asks the app's callback for one when there is none or the
/// API says it expired. Concurrent requests share one call of the callback.
actor TokenProvider {
  typealias Callback = @Sendable (_ userId: String) async throws -> String

  private let userId: String
  private let callback: Callback
  private var token: String?
  private var pending: Task<String, any Error>?

  init(userId: String, callback: @escaping Callback) {
    self.userId = userId
    self.callback = callback
  }

  /// The token in memory, or a new one from the callback.
  func current() async throws -> String {
    if let token { return token }
    return try await fetch()
  }

  /// A token other than `stale`: the one another request already fetched, or a new one.
  func refresh(replacing stale: String) async throws -> String {
    if let token, token != stale { return token }
    if token == stale { token = nil }
    return try await fetch()
  }

  /// Forgets `stale`, so the next request asks the callback again.
  func drop(_ stale: String) {
    if token == stale { token = nil }
  }

  func dropAll() {
    token = nil
    pending?.cancel()
    pending = nil
  }

  private func fetch() async throws -> String {
    if let pending { return try await pending.value }
    let task = Task { [userId, callback] in try await callback(userId) }
    pending = task
    defer { if pending == task { pending = nil } }
    let fetched = try await task.value
    if pending == task { token = fetched }
    return fetched
  }
}
