import Foundation

/// 一个手机连接的会话：鉴权状态机 + 帧收发 + 命令分发。
/// 所有逻辑运行在 `queue`（串行队列）上。
public final class Session {
    public enum State: String {
        case awaitingHello   // 等待鉴权
        case active          // 已鉴权
        case closed
    }

    public static let protocolVersion = 1
    public static let helloTimeout: TimeInterval = 5
    public static let idleTimeout: TimeInterval = 45

    public let connection: Connection
    public let queue: DispatchQueue
    public private(set) var state: State = .awaitingHello
    public private(set) var deviceName = "unknown"
    /// 是否订阅视频帧。
    public var wantsVideo = false
    public private(set) var isClosed = false
    public private(set) var connectedAt = Date()

    private var decoder = FrameDecoder()
    private let tokenStore: TokenStore
    private let lanGuard: LANGuard
    private let router: CommandRouter
    private let registry: SessionRegistry
    private var watchdog: DispatchSourceTimer?
    /// 最近活跃时刻（入站请求或视频帧外发都算）——只看屏幕不操作的会话靠视频流续命
    private var lastActivity = Date()

    public init(connection: Connection,
                tokenStore: TokenStore,
                lanGuard: LANGuard,
                router: CommandRouter,
                registry: SessionRegistry) {
        self.connection = connection
        self.tokenStore = tokenStore
        self.lanGuard = lanGuard
        self.router = router
        self.registry = registry
        self.queue = DispatchQueue(label: "macscreen.session")
    }

    public func start() {
        connection.onReady = { [weak self] in self?.enforceLanPolicy() }
        connection.onReceive = { [weak self] data in self?.handleInbound(data) }
        connection.onClose = { [weak self] reason in self?.handleClosed(reason) }
        connection.start()
        scheduleHelloTimeout()
        Log.i("新连接：\(connection.peerAddress)")
    }

    // MARK: - 鉴权

    private func enforceLanPolicy() {
        queue.async { [weak self] in
            guard let self = self, self.state != .closed else { return }
            guard self.lanGuard.isAllowed(self.connection.peerAddress) else {
                Log.i("拒绝非局域网连接：\(self.connection.peerAddress)")
                self.sendEvent(ServerEvent.error(code: "forbidden", message: "仅允许局域网同网段连接", id: nil))
                self.close(afterDelay: 0.3)
                return
            }
        }
    }

    private func handleHello(_ req: Request) {
        cancelWatchdog()
        // 网段二次校验
        guard lanGuard.isAllowed(connection.peerAddress) else {
            sendEvent(ServerEvent.error(code: "forbidden", message: "仅允许局域网同网段连接", id: req.id))
            close(afterDelay: 0.3)
            return
        }
        guard let token = req.token else {
            sendEvent(ServerEvent.error(code: "auth", message: "缺少 token", id: req.id))
            close(afterDelay: 0.3)
            return
        }
        guard token == tokenStore.token else {
            Log.i("鉴权失败：\(connection.peerAddress) token 不匹配")
            sendEvent(ServerEvent.error(code: "auth", message: "token 错误", id: req.id))
            close(afterDelay: 0.3)
            return
        }
        deviceName = req.deviceName ?? "phone"
        state = .active
        scheduleIdleWatchdog()
        Log.i("设备已连接：\(deviceName) (\(connection.peerAddress))")
        sendEvent(ServerEvent.helloAck(serverName: router.serverName,
                                       protocolVersion: Self.protocolVersion,
                                       mock: router.mockMode,
                                       id: req.id))
        sendEvent(ServerEvent.screenInfo(router.capture.currentInfo(), id: req.id))
        sendEvent(ServerEvent.captureState(enabled: router.capture.isRunning,
                                           permission: router.capture.permissionGranted,
                                           mock: router.capture.usingMock,
                                           id: req.id))
    }

    // MARK: - 入站处理

    func handleInbound(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            let frames = self.decoder.feed(data)
            guard !frames.isEmpty else { return }
            self.lastActivity = Date()
            for frame in frames {
                switch frame.kind {
                case .jpeg:
                    // 手机不会发视频；忽略
                    continue
                case .json:
                    guard let req = Request.parse(frame.payload) else {
                        self.sendEvent(ServerEvent.error(code: "bad-json", message: "无法解析 JSON", id: nil))
                        continue
                    }
                    switch self.state {
                    case .awaitingHello:
                        if req.op == "hello" {
                            self.handleHello(req)
                        } else {
                            self.sendEvent(ServerEvent.error(code: "auth", message: "请先发送 hello", id: req.id))
                        }
                    case .active:
                        let events = self.router.handle(req, session: self)
                        events.forEach { self.sendEvent($0) }
                    case .closed:
                        break
                    }
                }
            }
        }
    }

    // MARK: - 出站

    public func send(_ event: ServerEvent) {
        queue.async { [weak self] in self?.sendEvent(event) }
    }

    /// 视频帧：仅发给已订阅且背压未超限的会话（超限丢帧，保实时性）。
    func deliverVideoFrame(_ jpeg: Data) {
        queue.async { [weak self] in
            guard let self = self, self.state == .active, self.wantsVideo, !self.isClosed else { return }
            guard self.connection.sendBacklog < self.registry.videoBacklogLimit else { return }
            self.connection.send(ProtocolFrame.jpeg(jpeg).encoded())
            self.lastActivity = Date()
        }
    }

    private func sendEvent(_ event: ServerEvent) {
        guard !isClosed, let data = event.encoded() else { return }
        connection.send(data)
    }

    // MARK: - 关闭与看门狗

    func handleClosed(_ reason: String?) {
        queue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.isClosed = true
            self.state = .closed
            self.cancelWatchdog()
            self.registry.remove(self)
            Log.i("连接关闭：\(self.connection.peerAddress) \(reason ?? "")")
        }
    }

    /// 主动关闭（可延迟，让 error 先送达）。
    public func close(afterDelay delay: TimeInterval = 0) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.isClosed {
                self.isClosed = true
                self.state = .closed
                self.cancelWatchdog()
                self.registry.remove(self)
            }
            if delay > 0 {
                self.queue.asyncAfter(deadline: .now() + delay, execute: { self.connection.close() })
            } else {
                self.connection.close()
            }
        }
    }

    private func scheduleHelloTimeout() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.helloTimeout)
        t.setEventHandler { [weak self] in
            guard let self = self, self.state == .awaitingHello else { return }
            Log.i("鉴权超时：\(self.connection.peerAddress)")
            self.close()
        }
        watchdog = t
        t.resume()
    }

    /// 空闲看门狗：重复定时器周期检查 lastActivity。
    /// 活跃 = 有入站请求，或视频帧在外发（手机只看屏幕不操作时靠视频流续命）。
    private func scheduleIdleWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.idleTimeout, repeating: Self.idleTimeout)
        t.setEventHandler { [weak self] in
            guard let self = self, self.state == .active else { return }
            guard Date().timeIntervalSince(self.lastActivity) >= Self.idleTimeout else { return }
            Log.i("空闲超时断开：\(self.deviceName)")
            self.close()
        }
        watchdog = t
        t.resume()
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
