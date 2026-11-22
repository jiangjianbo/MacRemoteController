// swift-tools-version:5.6
import PackageDescription

/// iOS 客户端纯逻辑包：无平台 UI 依赖，macOS 上 swift test 直跑，
/// app 工程以文件引用方式复用 Sources/CoreLogic 下源码。
let package = Package(
    name: "CoreLogic",
    platforms: [.macOS(.v12), .iOS(.v13)],
    targets: [
        .target(name: "CoreLogic"),
        .testTarget(name: "CoreLogicTests", dependencies: ["CoreLogic"]),
    ]
)
