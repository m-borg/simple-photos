// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimplePhotos",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SimplePhotos", targets: ["SimplePhotos"])
    ],
    targets: [
        .executableTarget(
            name: "SimplePhotos",
            path: "Sources/SimplePhotos"
        ),
        .testTarget(
            name: "SimplePhotosTests",
            dependencies: ["SimplePhotos"],
            path: "Tests/SimplePhotosTests"
        )
    ]
)
