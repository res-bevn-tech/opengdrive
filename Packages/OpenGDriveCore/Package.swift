// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenGDriveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenGDriveCore", targets: ["OpenGDriveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "OpenGDriveCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenGDriveCoreTests",
            dependencies: ["OpenGDriveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
