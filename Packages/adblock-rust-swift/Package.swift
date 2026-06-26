// swift-tools-version: 6.3

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let swiftPMRustBuildRoot = "\(packageRoot)/.build/plugins/outputs/adblock-rust-swift/adblock-ffi/destination/RustBuildPlugin/out"
let swiftPMRustLibraryDirectory = "\(swiftPMRustBuildRoot)/lib"
let isRunningFromPackageDirectory =
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .standardizedFileURL.path
    == URL(fileURLWithPath: packageRoot).standardizedFileURL.path
let isXcodeBuildEnvironment = [
    "BUILD_DIR",
    "OBJROOT",
    "PROJECT_TEMP_DIR",
    "SRCROOT",
    "XCODE_VERSION_ACTUAL",
]
    .contains { ProcessInfo.processInfo.environment[$0] != nil }
let xcodeRustBuildRoot = ProcessInfo.processInfo.environment["OBJROOT"].map {
    "\($0)/BuildToolPluginIntermediates/adblock-rust-swift.output/adblock-ffi/RustBuildPlugin/out"
}
let discoveredXcodeRustBuildRoots: [String] = {
    let derivedDataURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    guard
        let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: derivedDataURL,
            includingPropertiesForKeys: nil
        )
    else {
        return []
    }

    return projectDirectories
        .filter { $0.lastPathComponent.hasPrefix("WebShield-") }
        .flatMap { projectDirectory in
            [
                projectDirectory
                    .appendingPathComponent("Build/Intermediates.noindex"),
                projectDirectory
                    .appendingPathComponent("Index.noindex/Build/Intermediates.noindex"),
            ]
        }
        .map {
            $0.appendingPathComponent("BuildToolPluginIntermediates/adblock-rust-swift.output/adblock-ffi/RustBuildPlugin/out").path
        }
}()
let xcodeRustBuildRoots =
    (xcodeRustBuildRoot.map { [$0] } ?? []) + discoveredXcodeRustBuildRoots
let includeSwiftPMRustBuildRoot = (!isXcodeBuildEnvironment && isRunningFromPackageDirectory)
    || FileManager.default.fileExists(atPath: swiftPMRustLibraryDirectory)
    || xcodeRustBuildRoots.isEmpty
let rustBuildRoots =
    (includeSwiftPMRustBuildRoot ? [swiftPMRustBuildRoot] : [])
    + xcodeRustBuildRoots
let rustIncludeFlags = rustBuildRoots.map { "-I\($0)/include" }
let rustLibraryFlags = rustBuildRoots.map { "-L\($0)/lib" } + ["-ladblock_ffi"]

let package = Package(
    name: "adblock-rust-swift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "adblock-rust-swift", targets: ["adblock-rust-swift"]),
    ],
    targets: [
        .target(
            name: "adblock-ffi",
            path: "Sources/adblock-ffi",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(rustIncludeFlags),
            ],
            linkerSettings: [
                .unsafeFlags(rustLibraryFlags),
                .linkedLibrary("c++"),
            ],
            plugins: [
                .plugin(name: "RustBuildPlugin"),
            ]
        ),
        .target(
            name: "adblock-rust-swift",
            dependencies: ["adblock-ffi"],
            path: "Sources/adblock-rust-swift"
        ),
        .plugin(
            name: "RustBuildPlugin",
            capability: .buildTool(),
            path: "Plugins/RustBuildPlugin"
        ),
        .testTarget(
            name: "adblock-rust-swiftTests",
            dependencies: ["adblock-rust-swift"],
            path: "Tests/adblock-rust-swiftTests"
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
