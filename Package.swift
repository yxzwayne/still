// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Still", targets: ["Still"])],
    targets: [
        .target(name: "StillCore"),
        .executableTarget(name: "Still", dependencies: ["StillCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "StillCoreTests", dependencies: ["StillCore"])
    ],
    swiftLanguageModes: [.v6]
)
