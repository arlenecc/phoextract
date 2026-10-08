// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoExtractor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(name: "PhotoExtractorCore"),
        .executableTarget(
            name: "PhotoExtractor",
            dependencies: ["PhotoExtractorCore"]
        ),
        .testTarget(
            name: "PhotoExtractorCoreTests",
            dependencies: ["PhotoExtractorCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
