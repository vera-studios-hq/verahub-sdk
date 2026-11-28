import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// The `VeraHub-Client` header: what a request comes from, as an RFC 9651 dictionary of strings.
///
/// It carries exactly these seven values, the ones publishers have been told about; a new value
/// is announced to publishers before an SDK sends it.
struct ClientContext: Sendable {
  /// `<sdk name>/<version>`.
  var sdk: String
  /// `<platform>/<OS version>`.
  var os: String
  var app: String?
  var build: String?
  var device: String?
  var locale: @Sendable () -> String?
  var timeZone: @Sendable () -> String?

  /// The values of this device and app; locale and time zone are read anew for each request.
  static func current(bundle: Bundle = .main) -> ClientContext {
    let info = bundle.infoDictionary ?? [:]
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return ClientContext(
      sdk: "swift/\(VeraHubClient.sdkVersion)",
      os: "\(platform)/\(version.majorVersion).\(version.minorVersion)"
        + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
      app: info["CFBundleShortVersionString"] as? String,
      build: info["CFBundleVersion"] as? String,
      device: deviceModel(),
      locale: { bcp47(Locale.current.identifier) },
      timeZone: { TimeZone.current.identifier })
  }

  /// The header's value, in the spec's order of names.
  var header: String {
    let values: [(String, String?)] = [
      ("sdk", sdk), ("os", os), ("app", app), ("build", build), ("device", device),
      ("locale", locale()), ("tz", timeZone()),
    ]
    return values.compactMap { name, value in
      guard let value, !value.isEmpty else { return nil }
      return "\(name)=\(Self.quoted(value))"
    }.joined(separator: ", ")
  }

  /// An RFC 9651 string of at most 128 characters: printable ASCII, other characters replaced.
  static func quoted(_ value: String) -> String {
    var text = ""
    for scalar in value.unicodeScalars.prefix(128) {
      let character = (0x20...0x7E).contains(scalar.value) ? Character(scalar) : "?"
      if character == "\\" || character == "\"" { text.append("\\") }
      text.append(character)
    }
    return "\"\(text)\""
  }

  /// A locale identifier as BCP 47: `de_DE` becomes `de-DE`, keywords such as `@calendar=…` go.
  static func bcp47(_ identifier: String) -> String? {
    let base = identifier.split(separator: "@").first.map(String.init) ?? identifier
    let tag = base.replacingOccurrences(of: "_", with: "-")
    return tag.isEmpty ? nil : tag
  }

  private static var platform: String {
    #if os(iOS)
      "ios"
    #elseif os(macOS)
      "macos"
    #elseif os(tvOS)
      "tvos"
    #elseif os(watchOS)
      "watchos"
    #elseif os(visionOS)
      "visionos"
    #elseif os(Linux)
      "linux"
    #else
      "unknown"
    #endif
  }

  /// The hardware model, such as `iPhone15,2`; a simulator names the model it simulates.
  private static func deviceModel() -> String? {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulated
    }
    #if os(macOS)
      var size = 0
      sysctlbyname("hw.model", nil, &size, nil, 0)
      if size > 0 {
        var model = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 {
          return String(
            decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
      }
    #endif
    var system = utsname()
    uname(&system)
    let machine = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return machine.isEmpty ? nil : machine
  }
}
