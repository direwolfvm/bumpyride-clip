// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BumpyRideClipCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ClipCore", targets: ["ClipCore"])],
    targets: [
        .target(name: "ClipCore", path: "BumpyRide Clip/Core"),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"], path: "Tests/ClipCoreTests")
    ]
)
