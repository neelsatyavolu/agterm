// swift-tools-version:6.0

// SwiftTerm 1.20.0 (MIT, github.com/migueldeicaza/SwiftTerm), trimmed to the library agterm uses.
// See README.md for what differs from upstream.

import PackageDescription

#if os(Linux)
// agterm: Linux (cloud sessions) builds only the headless terminal, as upstream does.
let swiftTerm = Target.target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Apple", "Mac", "iOS"])
#else
let swiftTerm = Target.target(
    name: "SwiftTerm",
    path: "Sources/SwiftTerm",
    exclude: ["Mac/README.md"],
    resources: [.process("Apple/Metal/Shaders.metal")]
)
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11), .iOS(.v14)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [swiftTerm],
    swiftLanguageModes: [.v5]
)
