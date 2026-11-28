import Foundation

#if canImport(os)
  import os
#endif

/// The SDK's log, off by default. It never contains a token or a code.
struct Log: Sendable {
  let level: VeraHubLogLevel

  func error(_ message: @autoclosure () -> String) { write(.error, message) }
  func info(_ message: @autoclosure () -> String) { write(.info, message) }
  func debug(_ message: @autoclosure () -> String) { write(.debug, message) }

  private func write(_ messageLevel: VeraHubLogLevel, _ message: () -> String) {
    guard messageLevel.rank <= level.rank, messageLevel != .off else { return }
    let text = message()
    #if canImport(os)
      let logger = Logger(subsystem: "io.verahub.sdk", category: "VeraHub")
      switch messageLevel {
      case .error: logger.error("\(text, privacy: .public)")
      case .info: logger.info("\(text, privacy: .public)")
      default: logger.debug("\(text, privacy: .public)")
      }
    #else
      FileHandle.standardError.write(Data("[VeraHub] \(text)\n".utf8))
    #endif
  }
}
