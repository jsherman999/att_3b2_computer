// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ATT3B2",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "ATT3B2",
            dependencies: ["SwiftTerm"],
            path: "Sources/ATT3B2"
        ),
    ]
)
