import Foundation
import PackagePlugin

@main
struct RustBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        func appending(_ components: [String], to base: URL) -> URL {
            components.reduce(base) { url, component in
                url.appendingPathComponent(component)
            }
        }

        let packageDirectory = context.package.directoryURL
        let pluginWorkDirectory = context.pluginWorkDirectoryURL
        let buildRoot = pluginWorkDirectory.appendingPathComponent("out")
        let libOutput = appending(["lib", "libadblock_ffi.a"], to: buildRoot)
        let stampOutput = buildRoot.appendingPathComponent("rust-build.stamp")

        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("build-rust.sh")

        return [
            .buildCommand(
                displayName: "Build Rust adblock FFI",
                executable: scriptURL,
                arguments: [
                    packageDirectory.path(percentEncoded: false),
                    pluginWorkDirectory.path(percentEncoded: false),
                ],
                inputFiles: [
                    scriptURL,
                    appending(["rust", "adblock-ffi", "Cargo.toml"], to: packageDirectory),
                    appending(["rust", "adblock-ffi", "build.rs"], to: packageDirectory),
                    appending(["rust", "adblock-ffi", "src", "lib.rs"], to: packageDirectory),
                    appending(["vendor", "adblock-rust", "Cargo.toml"], to: packageDirectory),
                ],
                outputFiles: [
                    libOutput,
                    stampOutput,
                ]
            ),
        ]
    }
}
