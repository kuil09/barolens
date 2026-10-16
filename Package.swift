// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Barolens",
    defaultLocalization: "en",
    platforms: [.macOS("26.4")],
    products: [.executable(name: "barolens", targets: ["Barolens"])],
    targets: [
        .executableTarget(name: "Barolens", path: "Sources/Barolens", resources: [.process("Resources")]),
        .testTarget(name: "BarolensTests", dependencies: ["Barolens"], path: "Tests/BarolensTests")
    ],
    swiftLanguageModes: [.v6]
)
