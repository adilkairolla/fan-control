// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FanKit", targets: ["FanKit"]),
        .executable(name: "fand", targets: ["fand"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
        .executable(name: "FanControlApp", targets: ["FanControlApp"]),
    ],
    targets: [
        .target(
            name: "FanKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "fand",
            dependencies: ["FanKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "fanctl",
            dependencies: ["FanKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FanControlApp",
            dependencies: ["FanKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command Line Tools ship neither XCTest nor swift-testing, so the
        // suite is a plain executable: `swift run CoreTests` / `make test`.
        .executableTarget(
            name: "CoreTests",
            dependencies: ["FanKit"],
            path: "Tests/CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
