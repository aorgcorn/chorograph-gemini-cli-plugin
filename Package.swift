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
            url: "https://github.com/aorgcorn/chorograph-plugin-sdk.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ChorographGeminiCLIPlugin",
            dependencies: [
                .product(name: "ChorographPluginSDK", package: "chorograph-plugin-sdk"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
    ]
)
