// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Remile",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Remile", targets: ["Remile"])],
    targets: [
        .executableTarget(name: "Remile"),
        .testTarget(name: "RemileTests", dependencies: ["Remile"])
    ]
)
