// swift-tools-version:5.9
import Foundation
import PackageDescription

// libatt_dmd.a comes from ../dmd_ffi (cargo build --release); scripts/build-app.sh builds it.
let dmdLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../dmd_ffi/target/release").standardized.path

let package = Package(
    name: "ATT3B2",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "CDMD",
            path: "Sources/CDMD",
            linkerSettings: [
                .unsafeFlags(["-L", dmdLib]),
                .linkedLibrary("att_dmd"),
            ]
        ),
        .executableTarget(
            name: "ATT3B2",
            dependencies: ["SwiftTerm", "CDMD"],
            path: "Sources/ATT3B2"
        ),
    ]
)
