import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Sends one HTTP request. The client's only way to the network, so tests and the preview module
/// can answer requests themselves.
package protocol Transport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` with nothing on disk: no cache, no cookies, no credentials.
struct URLSessionTransport: Transport {
  let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 20
    session = URLSession(configuration: configuration)
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, response)
  }
}
