// swift-tools-version:5.10
import PackageDescription

var targets: [Target] = [
    // Portable remux engine: ffprobe parsing, codec policy, ffmpeg argument
    // construction, progress parsing, cache keying. Foundation only, so it
    // builds and tests on Linux in a container.
    .target(
        name: "MilktoastCore",
        path: "Core"
    ),
    // Headless remux + handoff driver. Also the integration-test surface.
    // Installed as `milktoast`; the target name differs from the app's `Milktoast` module
    // because SwiftPM module names collide case-insensitively.
    .executableTarget(
        name: "milktoastcli",
        dependencies: ["MilktoastCore"],
        path: "CLI"
    ),
    .testTarget(
        name: "MilktoastTests",
        dependencies: ["MilktoastCore"],
        path: "Tests",
        resources: [.copy("Fixtures")]
    ),
]

var products: [Product] = [
    .library(name: "MilktoastCore", targets: ["MilktoastCore"]),
    .executable(name: "milktoastcli", targets: ["milktoastcli"]),
]

#if os(macOS)
// The SwiftUI launcher. Declared only on macOS hosts so Linux CI never tries
// to compile AppKit/SwiftUI; the bundle is assembled by Scripts/build.sh.
targets.append(
    .executableTarget(
        name: "Milktoast",
        dependencies: ["MilktoastCore"],
        path: "App"
    )
)
products.append(.executable(name: "Milktoast", targets: ["Milktoast"]))
#endif

let package = Package(
    name: "Milktoast",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
