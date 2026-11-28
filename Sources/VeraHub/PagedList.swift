/// A list the SDK loads page by page: call ``loadNext()`` until ``isComplete``.
///
/// Calls made at the same time load one page after the other, so no page is returned twice. A
/// page that failed to load is loaded again by the next call of ``loadNext()``, unless VeraHub can
/// no longer continue the list: then every later call throws
/// ``VeraHubError/Kind/listExpired``, and a new list starts from its first page.
public actor PagedList<Item: Sendable> {
  typealias Page = (items: [Item], next: String?)
  typealias Fetch = @Sendable (_ cursor: String?) async throws -> Page

  private let fetch: Fetch
  private var cursor: String?
  private var loading: Task<[Item], any Error>?
  /// The error that ended the list before its last page.
  private var expired: VeraHubError?

  /// Whether every page has been loaded.
  public private(set) var isComplete = false
  /// Every item loaded so far, in order.
  public private(set) var items: [Item] = []

  init(fetch: @escaping Fetch) {
    self.fetch = fetch
  }

  /// Loads the next page and returns its items; returns none once the list is complete.
  @discardableResult
  public func loadNext() async throws -> [Item] {
    while let loading {
      _ = try? await loading.value
      if self.loading == loading { self.loading = nil }
    }
    guard !isComplete else { return [] }
    if let expired { throw expired }
    // The task applies the page itself, so a call waiting for it sees the new cursor.
    let task = Task { try await self.loadPage() }
    loading = task
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func loadPage() async throws -> [Item] {
    let page: Page
    do {
      page = try await fetch(cursor)
    } catch let error as VeraHubError where error.problemCode == "cursor-invalid" && cursor != nil {
      let ended = VeraHubError(
        .listExpired, "VeraHub can no longer continue this list; start a new one.",
        requestId: error.requestId, status: error.status, problemCode: error.problemCode)
      expired = ended
      throw ended
    }
    cursor = page.next
    isComplete = page.next == nil
    items += page.items
    return page.items
  }
}
