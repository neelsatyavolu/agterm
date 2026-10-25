// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "agterm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
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
