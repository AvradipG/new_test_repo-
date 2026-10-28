// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScanMath",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ScanMath", targets: ["ScanMath"])],
    targets: [
        .target(name: "ScanMath"),
        .testTarget(name: "ScanMathTests", dependencies: ["ScanMath"]),
    ]
)
