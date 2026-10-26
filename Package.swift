// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "agterm",
    // iOS is for agterm Remote (Mobile/), which uses AgTermCore only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AgTermCore", targets: ["AgTermCore"])],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "AgTermCore"),
        .executableTarget(
            name: "AgTerm",
            dependencies: [
                "AgTermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "AgTermCoreTests", dependencies: ["AgTermCore"]),
    ]
)
