import Foundation

/// 进程执行抽象（测试时用 MockProcessRunner 记录命令）。
public protocol ProcessRunner: AnyObject {
    /// 同步执行，返回退出码。
    func run(launchPath: String, arguments: [String]) -> Int32
}

public final class SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(launchPath: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Log.e("进程执行失败 \(launchPath): \(error)")
            return -1
        }
    }
}

/// 开机自启管理：launchd LaunchAgents（系统内置机制）。
/// plist 写入 ~/Library/LaunchAgents/com.macscreen.agent.plist，RunAtLoad=true。
public final class LoginItemManager {
    public let label: String
    public let plistPath: String
    public let executablePath: String
    public let logFilePath: String
    public let runner: ProcessRunner

    public init(label: String = "com.macscreen.agent",
                plistPath: String? = nil,
                executablePath: String? = nil,
                logFilePath: String? = nil,
                runner: ProcessRunner = SystemProcessRunner()) {
        self.label = label
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.plistPath = plistPath ?? "\(home)/Library/LaunchAgents/\(label).plist"
        self.executablePath = executablePath
            ?? (Bundle.main.executableURL?.path ?? "")
        self.logFilePath = logFilePath ?? "\(home)/Library/Logs/macscreen-agent.log"
        self.runner = runner
    }

    /// 生成 launchd plist XML（纯函数，可测）。
    public static func plistXML(label: String, executablePath: String, logFilePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(logFilePath)</string>
            <key>StandardErrorPath</key>
            <string>\(logFilePath)</string>
        </dict>
        </plist>
        """
    }

    /// plist 内容与当前期望一致？（幂等判断）
    public func isUpToDate() -> Bool {
        guard let current = try? String(contentsOfFile: plistPath, encoding: .utf8) else { return false }
        return current == Self.plistXML(label: label, executablePath: executablePath, logFilePath: logFilePath)
    }

    public func isEnabled() -> Bool {
        guard FileManager.default.fileExists(atPath: plistPath) else { return false }
        let code = runner.run(launchPath: "/bin/launchctl", arguments: ["list", label])
        return code == 0
    }

    public func enable() throws {
        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let xml = Self.plistXML(label: label, executablePath: executablePath, logFilePath: logFilePath)
        try xml.write(toFile: plistPath, atomically: true, encoding: .utf8)
        // 幂等：先卸载旧的再加载
        runner.run(launchPath: "/bin/launchctl", arguments: ["unload", plistPath])
        let code = runner.run(launchPath: "/bin/launchctl", arguments: ["load", plistPath])
        guard code == 0 else {
            throw NSError(domain: "macscreen", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "launchctl load 失败（退出码 \(code)）"])
        }
        Log.i("开机自启已开启：\(plistPath)")
    }

    public func disable() {
        if FileManager.default.fileExists(atPath: plistPath) {
            runner.run(launchPath: "/bin/launchctl", arguments: ["unload", plistPath])
            try? FileManager.default.removeItem(atPath: plistPath)
        }
        Log.i("开机自启已关闭")
    }
}
