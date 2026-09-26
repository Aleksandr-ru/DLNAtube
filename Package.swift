// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DlnaTube",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DlnaTube", targets: ["DlnaTube"])],
    dependencies: [.package(path: "Vendor/YouTubeKit-0.4.9")],
    targets: [
        .executableTarget(name: "DlnaTube", dependencies: [.product(name: "YouTubeKit", package: "YouTubeKit-0.4.9")], path: "Sources/DlnaTube"),
        .testTarget(name: "DlnaTubeTests", dependencies: ["DlnaTube", .product(name: "YouTubeKit", package: "YouTubeKit-0.4.9")])
    ]
)
