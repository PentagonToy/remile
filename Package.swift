// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Deerstalker",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Deerstalker", targets: ["Deerstalker"])],
    targets: [.executableTarget(name: "Deerstalker")]
)
