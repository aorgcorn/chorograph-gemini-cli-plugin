// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChorographGeminiCLIPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "ChorographGeminiCLIPlugin",
            type: .dynamic,
            targets: ["ChorographGeminiCLIPlugin"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/chorograph/chorograph.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ChorographGeminiCLIPlugin",
            dependencies: [
                .product(name: "ChorographPluginSDK", package: "chorograph"),
            ]
        ),
    ]
)
