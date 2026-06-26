# adblock-rust-swift

SwiftPM package skeleton for using Brave's `adblock-rust` from Swift through a Rust `cxx` bridge and an Obj-C++ shim.

## Layout

- `vendor/adblock-rust`: vendored Brave `adblock-rust` source.
- `rust/adblock-ffi`: Rust `staticlib` crate exposing a CXX bridge.
- `Sources/adblock-ffi`: Obj-C++ wrapper target.
- `Sources/adblock-rust-swift`: public Swift API.
- `Plugins/RustBuildPlugin`: SwiftPM build tool plugin that runs Cargo for the active Apple target.

## Requirements

- Swift 6.3 toolchain or newer.
- Xcode with the Apple SDKs you build for.
- Rust and Cargo installed.
- Rust targets installed for the platforms you need:

```sh
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim
rustup target add x86_64-apple-ios
rustup target add aarch64-apple-darwin
rustup target add x86_64-apple-darwin
rustup target add aarch64-apple-visionos
rustup target add aarch64-apple-visionos-sim
```

## Build

```sh
swift build
swift test
```

The build tool plugin invokes:

```sh
cargo build --manifest-path rust/adblock-ffi/Cargo.toml --release --target <rust-triple>
```

For SwiftPM CLI builds, it writes the active Rust static library and generated CXX bridge headers under `.build/plugins/outputs/adblock-rust-swift/adblock-ffi/destination/RustBuildPlugin/out/`. For Xcode builds, the same outputs live under Xcode's `BuildToolPluginIntermediates` directory in DerivedData. `Package.swift` prefers Xcode's DerivedData roots for Xcode builds and only includes the SwiftPM `.build` root when running from the package directory, when that output already exists, or when no Xcode root is available.

## Public API

```swift
let rules = contentBlockerRules(fromFilterSet: "||example.com^\n")
print(rules.json)
print(rules.truncated)

let engine = AdblockEngine(filterSet: "example.com##.ad\n")
engine.useResources(json: "[]")

let resources = engine.cosmeticResources(for: "https://example.com")
let stylesheet = engine.stylesheetForCosmeticRules(
    classes: ["ad"],
    ids: [],
    exceptionsJSON: resources
)
```

`contentBlockerRules(fromFilterSet:)` caps output at 150,000 Safari content-blocker rules and reports whether truncation occurred.
