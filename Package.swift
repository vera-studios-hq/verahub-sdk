// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "VeraHub",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "VeraHub", targets: ["VeraHub"]),
    .library(name: "VeraHubPreview", targets: ["VeraHubPreview"]),
  ],
  targets: [
    .target(name: "VeraHub"),
    .target(name: "VeraHubPreview", dependencies: ["VeraHub"]),
    .testTarget(name: "VeraHubTests", dependencies: ["VeraHub"]),
    .testTarget(name: "VeraHubPreviewTests", dependencies: ["VeraHubPreview"]),
    .testTarget(name: "VeraHubIntegrationTests", dependencies: ["VeraHub"]),
  ]
)
