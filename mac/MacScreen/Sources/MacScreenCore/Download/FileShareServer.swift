import Foundation
import Network

/// 文件分享服务器：极小 HTTP/1.1（仅 GET/HEAD 单路径 `/file`）。
/// 手机扫菜单栏二维码 → 浏览器直接下载。文件任意类型，按 256KB 分块流式发送。
/// 连接前先过 LANGuard（仅回环/同网段），不接受公网访问——与主服务同一安全策略。
public final class FileShareServer {
    /// 相对主服务端口的偏移（主端口 9700 → 分享 9701）。
    public static let portOffset: UInt16 = 1
    /// 扫码 URL 的固定路径。
    public static let path = "/file"

    public let port: UInt16
    private let lanGuard: LANGuard
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "macscreen.fileshare")
    private static let chunkSize = 256 * 1024
    private static let maxHeaderBytes = 8 * 1024

    private var shareURL: URL?
    private var shareSize: UInt64 = 0

    public private(set) var stateDescription = "stopped"
    /// 绑定成功的实际端口（构造端口为 0 时由系统分配）。
    public private(set) var boundPort: UInt16 = 0

    public init(port: UInt16, lanGuard: LANGuard) {
        self.port = port
        self.lanGuard = lanGuard
    }

    // MARK: - 文件管理

    /// 当前分享的文件。
    public var currentFile: URL? { shareURL }

    /// 当前分享文件的大小（字节）；未分享时为 0。
    public var currentFileSize: UInt64 { shareSize }

    /// 设置要分享的文件（任意类型）。成功返回文件大小；文件不可读返回 nil。
    @discardableResult
    public func setFile(_ url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        shareURL = url
        shareSize = size
        return size
    }

    public func clearFile() {
        shareURL = nil
        shareSize = 0
    }

    /// 从可执行文件位置向上查找默认分享产物（先 dist APK，后 Android 构建输出）。
    public static func resolveDefaultShareFile(executablePath: String?) -> URL? {
        guard let exe = executablePath else { return nil }
        var dir = URL(fileURLWithPath: exe).deletingLastPathComponent()
        let candidates = ["dist/LAN-Mac-Controller-debug.apk",
                          "dist/MacScreenClient-debug.apk",
                          "android/MacScreenClient/app/build/outputs/apk/debug/app-debug.apk"]
        for _ in 0..<8 {
            for rel in candidates {
                let url = dir.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            if dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - 启停

    public func start() throws {
        guard shareURL != nil else {
            throw NSError(domain: "macscreen.fileshare", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "尚未设置要分享的文件"])
        }
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "macscreen.fileshare", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "非法端口 \(port)"])
        }
        let listener = try NWListener(using: .tcp, on: portValue)

        // NWListener 绑定错误异步上报，同步等待结果以便 fail fast（与 AgentServer 一致）
        final class StartBox {
            let sem = DispatchSemaphore(value: 0)
            var error: Error?
        }
        let box = StartBox()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? 0
                self?.stateDescription = "ready"
                Log.i("文件分享服务就绪 port=\(listener.port?.rawValue ?? 0)")
                box.sem.signal()
            case .failed(let error):
                self?.stateDescription = "failed: \(error)"
                Log.e("文件分享服务失败：\(error)")
                box.error = error
                box.sem.signal()
            case .waiting:
                self?.stateDescription = "waiting"
                box.error = NSError(domain: "macscreen.fileshare", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "监听 waiting（端口冲突）"])
                box.sem.signal()
            case .cancelled:
                self?.stateDescription = "cancelled"
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in
            self?.accept(nw)
        }
        self.listener = listener
        listener.start(queue: queue)

        if box.sem.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw NSError(domain: "macscreen.fileshare", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "监听启动超时（3s）"])
        }
        if let error = box.error {
            listener.cancel()
            throw error
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stateDescription = "stopped"
    }

    // MARK: - HTTP 处理

    private func accept(_ nw: NWConnection) {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self = self, case .ready = state else { return }
            // LANGuard 同策略：仅回环/同网段，公网直接拒绝
            let peer = nw.currentPath?.remoteEndpoint?.debugDescription ?? "unknown"
            if self.lanGuard.isAllowed(peer) {
                self.receiveHeader(nw, buf: Data())
            } else {
                Log.i("文件分享拒绝非局域网连接：\(peer)")
                nw.cancel()
            }
        }
        nw.start(queue: queue)
    }

    private func receiveHeader(_ nw: NWConnection, buf: Data) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buf
            if let data = data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handleRequest(head: buffer.subdata(in: buffer.startIndex..<range.lowerBound),
                                   connection: nw)
                return
            }
            if buffer.count > Self.maxHeaderBytes || error != nil || isComplete {
                nw.cancel()
                return
            }
            self.receiveHeader(nw, buf: buffer)
        }
    }

    private func handleRequest(head: Data, connection: NWConnection) {
        guard let line = String(data: head, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
            respondError(connection: connection, status: "400 Bad Request")
            return
        }
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else {
            respondError(connection: connection, status: "400 Bad Request")
            return
        }
        let method = parts[0].uppercased()
        let path = parts[1].components(separatedBy: "?")[0]
        guard method == "GET" || method == "HEAD" else {
            respondError(connection: connection, status: "405 Method Not Allowed")
            return
        }
        guard path == Self.path, let url = shareURL else {
            respondError(connection: connection, status: "404 Not Found")
            return
        }
        let headData = Self.responseHead(
            status: "200 OK",
            contentType: "application/octet-stream",
            contentLength: shareSize,
            filename: url.lastPathComponent)
        if method == "HEAD" {
            connection.send(content: headData, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: headData, completion: .contentProcessed { error in
            if error == nil {
                self.streamFile(connection: connection, url: url, offset: 0, handle: nil)
            } else {
                connection.cancel()
            }
        })
    }

    /// 分块流式发送文件体（整个连接复用一个 FileHandle），发送完毕关闭。
    private func streamFile(connection: NWConnection, url: URL, offset: UInt64, handle: FileHandle?) {
        guard offset < shareSize else {
            if let handle = handle { try? handle.close() }
            connection.cancel()
            return
        }
        let fileHandle: FileHandle
        if let existing = handle {
            fileHandle = existing
        } else {
            do { fileHandle = try FileHandle(forReadingFrom: url) } catch {
                connection.cancel()
                return
            }
        }
        let length: UInt64 = min(UInt64(Self.chunkSize), shareSize - offset)
        fileHandle.seek(toFileOffset: offset)
        let chunk = fileHandle.readData(ofLength: Int(length))
        guard chunk.count == Int(length) else {
            try? fileHandle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self = self else {
                try? fileHandle.close()
                connection.cancel()
                return
            }
            if error == nil {
                self.streamFile(connection: connection, url: url, offset: offset + length, handle: fileHandle)
            } else {
                try? fileHandle.close()
                connection.cancel()
            }
        })
    }

    private func respondError(connection: NWConnection, status: String) {
        let data = Self.responseHead(status: status, contentType: "text/plain; charset=utf-8",
                                     contentLength: 0, filename: nil)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - 纯函数（可测）

    /// 构造响应头。filename 非 nil 时带 Content-Disposition（ASCII 回退 + RFC 5987 UTF-8）。
    public static func responseHead(status: String, contentType: String,
                                    contentLength: UInt64, filename: String?) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(contentLength)\r\n"
        if let filename = filename {
            head += "Content-Disposition: \(contentDisposition(filename))\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    /// Content-Disposition 值：ASCII 回退名 + RFC 5987 filename*（支持中文等非 ASCII 文件名）。
    public static func contentDisposition(_ filename: String) -> String {
        let asciiFallback = String(filename.map { char -> Character in
            (char.isASCII && char != Character("\"") && char != Character("\\")) ? char : "_"
        })
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? asciiFallback
        return "attachment; filename=\"\(asciiFallback)\"; filename*=UTF-8''\(encoded)"
    }
}
