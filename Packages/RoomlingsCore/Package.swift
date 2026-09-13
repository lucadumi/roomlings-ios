// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoomlingsCore",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "RoomlingsCore", targets: ["RoomlingsCore"])
    ],
    targets: [
        .target(name: "RoomlingsCore"),
        .testTarget(name: "RoomlingsCoreTests", dependencies: ["RoomlingsCore"])
    ],
    swiftLanguageModes: [.v6]
)
