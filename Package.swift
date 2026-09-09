// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SeoulLocalAgent",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "SeoulLocalAgent", targets: ["SeoulLocalAgent"])],
    targets: [
        .executableTarget(
            name: "SeoulLocalAgent",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SeoulLocalAgentTests", dependencies: ["SeoulLocalAgent"])
    ]
)
