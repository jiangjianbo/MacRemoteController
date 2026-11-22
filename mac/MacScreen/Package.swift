// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "MacScreen",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "MacScreenCore", path: "Sources/MacScreenCore"),
        .executableTarget(name: "MacScreenAgent",
                          dependencies: ["MacScreenCore"],
                          path: "Sources/MacScreenAgent"),
        .executableTarget(name: "PhoneSimulator",
                          dependencies: ["MacScreenCore"],
                          path: "Sources/PhoneSimulator"),
        .testTarget(name: "MacScreenCoreTests",
                    dependencies: ["MacScreenCore"],
                    path: "Tests/MacScreenCoreTests")
    ]
)
