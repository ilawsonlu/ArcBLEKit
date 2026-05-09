// swift-tools-version: 5.5
import PackageDescription

let package = Package(
    name: "ArcBLEKit",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(name: "ArcBLEKit", targets: ["ArcBLEKit"])
    ],
    targets: [
        .target(name: "ArcBLEKit"),
        .testTarget(name: "ArcBLEKitTests", dependencies: ["ArcBLEKit"])
    ]
)
