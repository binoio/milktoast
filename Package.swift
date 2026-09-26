// swift-tools-version:5.10
import PackageDescription

var targets: [Target] = [
    // getxattr/setxattr. Swift's Glibc module does not re-export
    // <sys/xattr.h>, so the header is surfaced through a module map.
    .systemLibrary(name: "CXattr", path: "CXattr"),
    // Portable remux engine: ffprobe parsing, codec policy, ffmpeg argument
    // construction, progress parsing, cache keying. Foundation only, so it
    // builds and tests on Linux in a container.
    .target(
        name: "MilktoastCore",
        dependencies: ["CXattr"],
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

var dependencies: [Package.Dependency] = []

#if os(macOS)
// Sparkle auto-updates (Developer ID distribution only; the framework is
// embedded in Contents/Frameworks by Scripts/build.sh). Declared only on macOS
// hosts so Linux CI never resolves it.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"))

// The SwiftUI launcher. Declared only on macOS hosts so Linux CI never tries
// to compile AppKit/SwiftUI; the bundle is assembled by Scripts/build.sh.
targets.append(
    .executableTarget(
        name: "Milktoast",
        dependencies: [
            "MilktoastCore",
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
        ],
        path: "App",
        linkerSettings: [
            .unsafeFlags(
                ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                .when(platforms: [.macOS])
            ),
        ]
    )
)
products.append(.executable(name: "Milktoast", targets: ["Milktoast"]))
#endif

let package = Package(
    name: "Milktoast",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
