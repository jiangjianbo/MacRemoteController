import Foundation
import Network

/// Mac agent TCP 客户端（对齐 Android MacConnection 语义）。
/// 协议帧编解码直接复用 mac/MacScreenCore 的 ProtocolFrame/FrameDecoder；
/// 事件为宽松解析的单层 JSON dict（op 必有），响应解析由 SessionModel 完成。
final class MacClient {
    struct HelloAck {
        let ok: Bool
        let protocolVersion: Int
        let serverName: String
        let mock: Bool
    }

    enum ConnectError: Error, LocalizedError {
        case badEndpoint
        case timeout(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .badEndpoint: return "地址或端口无效"
            case .timeout(let m): return "握手超时：\(m)"
            case .refused(let m): return m
            }
        }
    }

    // MARK: 回调（全部主线程）
    var onHelloAck: ((HelloAck) -> Void)?
    var onScreenInfo: (([String: Any]) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onEvent: ((String, [String: Any]) -> Void)?   // 除上述外的 JSON 事件（windows/ok/error/…）
    var onClosed: ((String?) -> Void)?

    private(set) var connected = false
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "macscreen.client")
    private var decoder = FrameDecoder()
    private var handshakeDone = false

    // MARK: 连接与握手

    /// NWConnection 无阻塞读：用信号量在专用等待队列上完成同步握手（对齐 Android 阻塞 connect）。
    func connect(host: String, port: UInt16, token: String, deviceName: String,
                 timeout: TimeInterval = 5, completion: @escaping (Result<HelloAck, Error>) -> Void) {
        close(reason: nil, notify: false)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(ConnectError.badEndpoint))
            return
        }
        handshakeDone = false
        decoder.reset()
        let nw = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = nw

        // 握手结果只完成一次（queue 回调与调用线程超时竞争时加锁去重）。
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<HelloAck, Error>?
        func finish(_ r: Result<HelloAck, Error>) {
            lock.lock()
            let first = (result == nil)
            if first { result = r }
            lock.unlock()
            if first {
                handshakeDone = true
                semaphore.signal()
            }
        }
        func currentResult() -> Result<HelloAck, Error>? {
            lock.lock(); defer { lock.unlock() }
            return result
        }
        func handshakeFinished() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return handshakeDone
        }

        nw.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // 连接即发 hello（必须在读循环前；Mac 端 5s 未收到 hello 会断开）
                self.sendOnQueue(Requests.hello(token: token, deviceName: deviceName))
                self.receiveLoop(onHandshakeEvent: { dict in
                    // 握手阶段事件过滤（queue 上回调）
                    guard !handshakeFinished() else { return false }   // false = 交给常规回调
                    let op = dict["op"] as? String ?? ""
                    if op == "hello-ack" {
                        let ack = HelloAck(ok: dict["ok"] as? Bool ?? false,
                                           protocolVersion: dict["protocol"] as? Int ?? 1,
                                           serverName: dict["serverName"] as? String ?? "Mac",
                                           mock: dict["mock"] as? Bool ?? false)
                        if ack.ok {
                            finish(.success(ack))
                        } else {
                            finish(.failure(ConnectError.refused("握手被拒绝")))
                        }
                    } else if op == "error" {
                        finish(.failure(ConnectError.refused(dict["message"] as? String ?? "server error")))
                    }
                    // 其余事件（screen-info 等）握手成功后由 receiveLoop 继续补发
                    return true
                })
            case .failed(let error):
                finish(.failure(ConnectError.timeout(error.localizedDescription)))
            case .cancelled:
                finish(.failure(ConnectError.timeout("连接被取消")))
            default:
                break
            }
        }

        nw.start(queue: queue)
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut, currentResult() == nil {
            finish(.failure(ConnectError.timeout("\(host):\(port) 5 秒无响应")))
            close(reason: nil, notify: false)
        }
        let finalResult = currentResult() ?? .failure(ConnectError.timeout("握手无结果"))

        if case .success(let ack) = finalResult {
            connected = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onHelloAck?(ack)
                completion(.success(ack))
            }
        } else {
            DispatchQueue.main.async { completion(finalResult) }
        }
    }

    // MARK: 收发

    /// 发送请求 dict（整帧原子写在 queue 上天然串行）。
    func send(_ dict: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self, self.connected, let frame = ProtocolFrame.json(dict) else { return }
            self.sendRaw(frame.encoded())
        }
    }

    private func sendOnQueue(_ dict: [String: Any]) {
        // 仅在 queue 上调用（stateUpdateHandler 已在 queue）
        guard let frame = ProtocolFrame.json(dict) else { return }
        sendRaw(frame.encoded())
    }

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(onHandshakeEvent: @escaping ([String: Any]) -> Bool) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                let frames = self.decoder.feed(data)
                var deferred: [ProtocolFrame] = []
                for frame in frames {
                    switch frame.kind {
                    case .jpeg:
                        if self.handshakeDone { self.dispatchFrame(frame.payload) }
                        // 握手期不应有帧，丢弃
                    case .json:
                        guard let obj = try? JSONSerialization.jsonObject(with: frame.payload),
                              let dict = obj as? [String: Any] else { continue }
                        let consumed = onHandshakeEvent(dict)
                        if !consumed { deferred.append(frame) }
                    }
                }
                if !deferred.isEmpty { self.dispatchEvents(deferred) }
            }
            if isComplete || error != nil {
                self.handleRemoteClose(error)
            } else {
                self.receiveLoop(onHandshakeEvent: onHandshakeEvent)
            }
        }
    }

    private func dispatchEvents(_ frames: [ProtocolFrame]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.connected else { return }
            for frame in frames {
                guard let obj = try? JSONSerialization.jsonObject(with: frame.payload),
                      let dict = obj as? [String: Any],
                      let op = dict["op"] as? String else { continue }
                switch op {
                case "screen-info":
                    self.onScreenInfo?(dict)
                default:
                    self.onEvent?(op, dict)
                }
            }
        }
    }

    private func dispatchFrame(_ payload: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.connected else { return }
            self.onFrame?(payload)
        }
    }

    private func handleRemoteClose(_ error: NWError?) {
        let wasConnected = connected
        connected = false
        guard wasConnected else { return }
        let reason = error.map { "network: \($0)" }
        DispatchQueue.main.async { [weak self] in
            self?.onClosed?(reason)
        }
    }

    /// 主动断开；notify=false 用于静默重建（重连前清理）。
    /// 防回调环由调用方保证（SessionModel 手动断开时先摘 onClosed）。
    func close(reason: String?, notify: Bool = true) {
        connected = false
        let old = connection
        connection = nil
        old?.cancel()
        if notify {
            let r = reason
            DispatchQueue.main.async { [weak self] in
                self?.onClosed?(r)
            }
        }
    }
}
