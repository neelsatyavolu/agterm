// swift-tools-version:5.10
import PackageDescription

var dependencies: [Package.Dependency] = [.package(path: "Vendor/SwiftTerm")]
var targets: [Target] = [
    .target(name: "AgTermCore"),
    .target(
        name: "AgTermSessionKit",
        dependencies: ["AgTermCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
    ),
    .testTarget(name: "AgTermCoreTests", dependencies: ["AgTermCore"]),
    .testTarget(
        name: "AgTermSessionKitTests",
        dependencies: ["AgTermCore", "AgTermSessionKit", .product(name: "SwiftTerm", package: "SwiftTerm")]
    ),
]

#if os(macOS)
// The Mac app. Its own executable is also the sessions helper (`agterm --sessions-helper`).
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"))
targets.append(
    .executableTarget(
        name: "AgTerm",
        dependencies: [
            "AgTermCore",
            "AgTermSessionKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Sparkle", package: "Sparkle"),
        ],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )
)
#else
// Cloud sessions: the sessions helper on its own, for Linux machines with no app.
targets.append(.executableTarget(name: "agterm-sessions", dependencies: ["AgTermSessionKit"]))
#endif

let package = Package(
    name: "agterm",
    // iOS is for agterm Remote (Mobile/), which uses AgTermCore only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AgTermCore", targets: ["AgTermCore"]),
    ],
    dependencies: dependencies,
    targets: targets
)
