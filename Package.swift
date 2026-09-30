// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Quotaback",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Quotaback",
            path: "Sources/Quotaback"
        ),
        .testTarget(
            name: "QuotabackTests",
            dependencies: ["Quotaback"],
            path: "Tests/QuotabackTests"
        ),
    ]
)
