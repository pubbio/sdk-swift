// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pubb",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [.library(name: "Pubb", targets: ["Pubb"])],
    targets: [
        .target(name: "Pubb"),
        .testTarget(name: "PubbTests", dependencies: ["Pubb"]),
        .executableTarget(name: "PubbExample", dependencies: ["Pubb"], path: "Examples")
    ]
)
