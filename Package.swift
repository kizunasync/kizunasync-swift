// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "kizunasync-swift",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "KizunaSync", targets: ["KizunaSync"]),
    // The engine binary alone, which @kizunasync/rn-uniffi links. Apps depend on KizunaSync.
    .library(name: "KizunaSyncEngine", targets: ["KizunaSyncFfiRust"]),
  ],
  targets: [
    .binaryTarget(
      name: "KizunaSyncFfiRust",
      url: "https://github.com/kizunasync/kizunasync/releases/download/v0.2.6-alpha.3/KizunaSyncFfi.xcframework.zip",
      checksum: "f2f7c481927ee14e585b9dc91228fb8f0f8f8bd4bd0861d3766944c65638e5cb"
    ),
    .target(
      name: "KizunaSyncFfi",
      dependencies: ["KizunaSyncFfiRust"],
      path: "Sources/KizunaSyncFfi"
    ),
    .target(
      name: "KizunaSync",
      dependencies: ["KizunaSyncFfi"],
      path: "Sources/KizunaSync"
    ),
  ]
)
