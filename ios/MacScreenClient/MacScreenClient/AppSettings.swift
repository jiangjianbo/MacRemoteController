import Foundation
import UIKit

/// 用户设置（UserDefaults），字段与 Android AppSettings 对齐。
/// e2e/自动化可用 simctl launch 传 `-autoConnectHost ...` 注入（UserDefaults 参数注册机制）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var host: String { didSet { d.set(host, forKey: "host") } }
    @Published var port: Int { didSet { d.set(port, forKey: "port") } }
    @Published var token: String { didSet { d.set(token, forKey: "token") } }
    @Published var deviceName: String { didSet { d.set(deviceName, forKey: "deviceName") } }
    /// "local" | "cloud"
    @Published var voiceEngine: String { didSet { d.set(voiceEngine, forKey: "voiceEngine") } }
    @Published var cloudUrl: String { didSet { d.set(cloudUrl, forKey: "cloudUrl") } }
    @Published var cloudKey: String { didSet { d.set(cloudKey, forKey: "cloudKey") } }
    @Published var cloudModel: String { didSet { d.set(cloudModel, forKey: "cloudModel") } }
    /// "openai" | "raw"
    @Published var cloudStyle: String { didSet { d.set(cloudStyle, forKey: "cloudStyle") } }
    /// 发送文本后是否自动回车
    @Published var voiceSubmit: Bool { didSet { d.set(voiceSubmit, forKey: "voiceSubmit") } }

    private init() {
        host = d.string(forKey: "host") ?? ""
        port = d.object(forKey: "port") as? Int ?? 9700
        token = d.string(forKey: "token") ?? ""
        deviceName = d.string(forKey: "deviceName") ?? UIDeviceNameProvider.name
        voiceEngine = d.string(forKey: "voiceEngine") ?? "local"
        cloudUrl = d.string(forKey: "cloudUrl") ?? ""
        cloudKey = d.string(forKey: "cloudKey") ?? ""
        cloudModel = d.string(forKey: "cloudModel") ?? "whisper-1"
        cloudStyle = d.string(forKey: "cloudStyle") ?? "openai"
        voiceSubmit = d.bool(forKey: "voiceSubmit")
    }

    /// 与 Android cloudTranscriberConfig 一致：固定 language=zh、responseField=text。
    var cloudConfig: CloudTranscriberConfig {
        CloudTranscriberConfig(url: cloudUrl, apiKey: cloudKey, model: cloudModel,
                               style: cloudStyle, language: "zh", responseField: "text")
    }
}

enum UIDeviceNameProvider {
    static let name: String = {
        // iPhone 设备名（设置>通用>关于本机>名称）；模拟器上为 "iPhone 13" 等
        UIDevice.current.name
    }()
}
