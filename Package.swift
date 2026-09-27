// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DlnaTube",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DLNAtube", targets: ["DLNAtube"])],
    dependencies: [.package(url: "https://github.com/alexeichhorn/YouTubeKit.git", exact: "0.4.9")],
    targets: [
        .executableTarget(name: "DLNAtube", dependencies: [.product(name: "YouTubeKit", package: "youtubekit")], path: "Sources/DlnaTube"),
        .testTarget(name: "DlnaTubeTests", dependencies: ["DLNAtube", .product(name: "YouTubeKit", package: "youtubekit")])
    ]
)
