// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "DJQueue",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DJQCore", targets: ["DJQCore"]),
    .executable(name: "djq", targets: ["djq"]),
    .executable(name: "DJQueueApp", targets: ["DJQueueApp"]),
  ],
  targets: [
    .target(name: "DJQCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "djq", dependencies: ["DJQCore"]),
    .executableTarget(name: "DJQueueApp", dependencies: ["DJQCore"]),
    .testTarget(name: "DJQCoreTests", dependencies: ["DJQCore"]),
  ],
  swiftLanguageModes: [.v5]
)
