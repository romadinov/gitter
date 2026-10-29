// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Gitter",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Gitter",
            path: "Sources/Gitter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GitterTests",
            dependencies: ["Gitter"],
            path: "Tests/GitterTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
