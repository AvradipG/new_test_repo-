// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PaperCore", targets: ["PaperCore"])],
    targets: [
        .target(name: "PaperCore"),
        .testTarget(name: "PaperCoreTests", dependencies: ["PaperCore"]),
    ]
)
