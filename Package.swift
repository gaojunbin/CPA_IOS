// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CPAIOS",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "CPAKit", targets: ["CPAKit"]),
        .executable(name: "CPAKitValidation", targets: ["CPAKitValidation"])
    ],
    targets: [
        .target(name: "CPAKit", path: "Sources/CPAKit"),
        .executableTarget(
            name: "CPAKitValidation",
            dependencies: ["CPAKit"],
            path: "Validation"
        )
    ]
)
