# Kizuna Sync for Swift

`Ksync` is the Swift app client for [Kizuna Sync](https://kizunasync.com): offline reads and writes on local SQLite, an outbox that syncs through your Supabase project, and typed access to the Rust engine through UniFFI.

## Install

In Xcode choose File → Add Package Dependencies and enter `https://github.com/kizunasync/ksync-swift`, or declare the dependency in `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/kizunasync/ksync-swift", from: "0.1.0"),
],
targets: [
  .target(
    name: "App",
    dependencies: [.product(name: "Ksync", package: "ksync-swift")]
  ),
]
```

```swift
import Ksync
```

Platforms: iOS 16 and macOS 13 or later. The package links the prebuilt `KsyncFfi` XCFramework, so the app project needs no Rust toolchain.

## What is inside

| Path | Contents |
|---|---|
| `Sources/Ksync` | `KsyncClient`, `KsyncScheduler`, and their configuration types |
| `Sources/KsyncFfi` | UniFFI-generated Swift over the Rust engine |
| `KsyncFfiRust` | Binary target: `KsyncFfi.xcframework.zip` from the matching `kizunasync/kizunasync` release, pinned by checksum |

## Documentation and source

Reference: [Swift: Introduction](https://kizunasync.com/docs/reference/swift/introduction). This repository is rendered by the release workflow of [kizunasync/kizunasync](https://github.com/kizunasync/kizunasync); open issues and pull requests there. Each tag matches the engine version it links.

## License

Apache-2.0. See [LICENSE](./LICENSE).
