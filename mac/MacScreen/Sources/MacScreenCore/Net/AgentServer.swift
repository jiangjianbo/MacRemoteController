import Foundation
import Network

/// TCP 服务器：NWListener + Bonjour 自动发现（系统内置 `_macscreen._tcp`）。
public final class AgentServer {
    public let port: UInt16
    public let enableBonjour: Bool
    public private(set) var stateDescription = "stopped"

    private let serviceName: String
    private let lanGuard: LANGuard
    private let tokenStore: TokenStore
    private let router: CommandRouter
    private let registry: SessionRegistry
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "macscreen.server")

    public init(port: UInt16,
                serverName: String,
                lanGuard: LANGuard,
                tokenStore: TokenStore,
                router: CommandRouter,
                registry: SessionRegistry,
                enableBonjour: Bool = true) {
        self.port = port
        self.serviceName = serverName
        self.lanGuard = lanGuard
        self.tokenStore = tokenStore
        self.router = router
        self.registry = registry
        self.enableBonjour = enableBonjour
    }

    public func start() throws {
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "macscreen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "非法端口 \(port)"])
        }
        let listener = try NWListener(using: .tcp, on: portValue)
        if enableBonjour {
            listener.service = NWListener.Service(
                name: serviceName,
                type: "_macscreen._tcp",
                domain: "local",
                txtRecord: NWTXTRecord(["v": "1", "proto": "1"]))
        }

        // NWListener 的绑定错误（如端口被占 EADDRINUSE）经 stateUpdateHandler 异步上报，
        // 这里用信号量同步等待结果，让调用方能 fail fast 而不是带病运行。
        final class StartBox {
            let sem = DispatchSemaphore(value: 0)
            var error: Error?
        }
        let box = StartBox()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.stateDescription = "ready"
                Log.i("服务器就绪 port=\(self?.port ?? 0) bonjour=\(self?.enableBonjour ?? false)")
                box.sem.signal()
            case .failed(let error):
                self?.stateDescription = "failed: \(error)"
                Log.e("服务器失败：\(error)")
                box.error = error
                box.sem.signal()
            case .waiting:
                self?.stateDescription = "waiting"
                box.error = NSError(domain: "macscreen", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey:
                                        "监听处于 waiting（端口或 Bonjour 冲突）"])
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
            throw NSError(domain: "macscreen", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "监听启动超时（3s）"])
        }
        if let error = box.error {
            listener.cancel()
            throw error
        }
    }

    private func accept(_ nw: NWConnection) {
        let adapter = NWConnectionAdapter(nw)
        let session = Session(connection: adapter,
                              tokenStore: tokenStore,
                              lanGuard: lanGuard,
                              router: router,
                              registry: registry)
        registry.add(session)
        session.start()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stateDescription = "stopped"
    }
}
