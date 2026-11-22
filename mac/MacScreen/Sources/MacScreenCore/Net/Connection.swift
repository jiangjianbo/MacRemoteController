import Foundation
import Network

/// 连接抽象：屏蔽 NWConnection，便于用 FakeConnection 做单元测试。
public protocol Connection: AnyObject {
    /// 对端地址（如 "127.0.0.1:52344"），未知时为 "unknown"。
    var peerAddress: String { get }
    /// 收到原始字节（连接队列上回调）。
    var onReceive: ((Data) -> Void)? { get set }
    /// 连接就绪（可获取对端地址）。
    var onReady: (() -> Void)? { get set }
    /// 连接关闭（错误原因或 nil）。
    var onClose: ((String?) -> Void)? { get set }
    /// 发送积压数（背压控制用）。
    var sendBacklog: Int { get }
    func start()
    func send(_ data: Data)
    func close()
}

/// NWConnection 适配器。所有回调投递到 `queue`（保证与 Session 串行一致）。
public final class NWConnectionAdapter: Connection {
    private let nw: NWConnection
    private let queue: DispatchQueue
    private var backlog = 0
    private var didClose = false

    public var peerAddress: String = "unknown"
    public var onReceive: ((Data) -> Void)?
    public var onReady: (() -> Void)?
    public var onClose: ((String?) -> Void)?

    public init(_ nw: NWConnection, queue: DispatchQueue? = nil) {
        self.nw = nw
        self.queue = queue ?? DispatchQueue(label: "macscreen.conn")
    }

    public var sendBacklog: Int { backlog }

    public func start() {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let remote = self.nw.currentPath?.remoteEndpoint {
                    self.peerAddress = remote.debugDescription
                }
                self.onReady?()
                self.receiveLoop()
            case .failed(let error):
                self.finish(String(describing: error))
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        nw.start(queue: queue)
    }

    public func send(_ data: Data) {
        guard !didClose else { return }
        backlog += 1
        nw.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.backlog = max(0, self.backlog - 1)
        })
    }

    public func close() {
        finish(nil)
        nw.cancel()
    }

    private func finish(_ reason: String?) {
        guard !didClose else { return }
        didClose = true
        onClose?(reason)
    }

    private func receiveLoop() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.onReceive?(data)
            }
            if error != nil {
                self.finish(String(describing: error))
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receiveLoop()
            }
        }
    }
}
