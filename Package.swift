// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ksync-swift",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "Ksync", targets: ["Ksync"]),
  ],
  targets: [
    .binaryTarget(
      name: "KsyncFfiRust",
      url: "https://github.com/kizunasync/kizunasync/releases/download/v0.1.0/KsyncFfi.xcframework.zip",
      checksum: "e1159ef2a38d1378ce9b8487ac78f6fbc94c7f898573ca0146406b2d4feef0c6"
    ),
    .target(
      name: "KsyncFfi",
      dependencies: ["KsyncFfiRust"],
      path: "Sources/KsyncFfi"
    ),
    .target(
      name: "Ksync",
      dependencies: ["KsyncFfi"],
      path: "Sources/Ksync"
    ),
  ]
)
