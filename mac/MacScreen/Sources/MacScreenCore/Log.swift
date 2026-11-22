import Foundation
import Darwin

/// 统一日志：同时写文件与 stderr。线程安全。
public final class Log {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "macscreen.log")
    private var fileHandle: FileHandle?
    public private(set) var path: String?

    private init() {}

    /// 初始化日志文件；目录不存在则创建。
    public func setup(file: String?) {
        queue.sync {
            guard let file = file, !file.isEmpty else { return }
            let dir = (file as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file) {
                FileManager.default.createFile(atPath: file, contents: nil)
            }
            self.fileHandle = FileHandle(forWritingAtPath: file)
            // 追加而非覆写：重启 agent 不能把上次日志从头部抹掉
            self.fileHandle?.seekToEndOfFile()
            self.path = file
        }
    }

    public func info(_ s: String)  { write("INFO", s) }
    public func error(_ s: String) { write("ERROR", s) }
    public func debug(_ s: String) { write("DEBUG", s) }

    public static func i(_ s: String) { shared.info(s) }
    public static func e(_ s: String) { shared.error(s) }
    public static func d(_ s: String) { shared.debug(s) }

    private func write(_ level: String, _ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        let data = Data(line.utf8)
        queue.sync {
            FileHandle.standardError.write(data)
            fileHandle?.write(data)
        }
    }
}
