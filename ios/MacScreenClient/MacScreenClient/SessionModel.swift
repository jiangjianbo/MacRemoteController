import Foundation
import SwiftUI

/// 全局会话状态：连接生命周期、事件分发、ping/重连保活、窗口列表、e2e 日志。
final class SessionModel: ObservableObject {
    static let shared = SessionModel()

    // MARK: UI 状态（主线程）
    @Published var inViewer = false
    @Published var connecting = false
    @Published var connected = false
    @Published var statusLine = ""
    @Published var serverMock = false
    @Published var screenInfo: ScreenInfoData?
    @Published var windows: [WindowInfoData]?
    @Published var toast: String?
    @Published var zoomed = false
    /// 录音状态（VoiceManager 驱动，覆盖层显示）
    @Published var recording = false

    let client = MacClient()
    let settings = AppSettings.shared
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var lastFrameAt = Date.distantPast
    private var manualDisconnect = false
    private var resumed = true

    /// e2e 注入：`simctl launch <app> -autoConnectHost h -autoConnectPort p -autoConnectToken t -e2e 1`
    private let autoHost = UserDefaults.standard.string(forKey: "autoConnectHost")
    private let autoPort = UserDefaults.standard.integer(forKey: "autoConnectPort")
    private let autoToken = UserDefaults.standard.string(forKey: "autoConnectToken")
    private let e2eMode = UserDefaults.standard.string(forKey: "e2e") == "1"
    private var e2eStep = 0

    private init() {
        bindClient()
        if autoHost != nil, autoPort > 0, autoToken != nil {
            // 启动即自动连接进投屏页（e2e/演示）
            connect(host: autoHost!, port: autoPort, token: autoToken!)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.resumed = true
            self?.onResumed()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.resumed = false
        }
    }

    // MARK: 连接

    func connect(host: String? = nil, port: Int? = nil, token: String? = nil) {
        guard !connecting, !connected else { return }
        let h = host ?? settings.host
        let p = port ?? settings.port
        let t = token ?? settings.token
        guard !h.isEmpty, p > 0, !t.isEmpty else {
            statusLine = NSLocalizedString("err_missing_pairing", comment: "")
            return
        }
        if host != nil || port != nil || token != nil {
            // 显式参数（含自动连接）记住为默认
            settings.host = h; settings.port = p; settings.token = t
        }
        connecting = true
        manualDisconnect = false
        statusLine = NSLocalizedString("connecting", comment: "")
        client.onClosed = { [weak self] reason in self?.handleClosed(reason) }
        client.connect(host: h, port: UInt16(clamping: p), token: t,
                       deviceName: settings.deviceName) { [weak self] result in
            guard let self = self else { return }
            self.connecting = false
            switch result {
            case .failure(let error):
                self.statusLine = error.localizedDescription
                self.scheduleReconnect()
            case .success(let ack):
                self.connected = true
                self.serverMock = ack.mock
                self.statusLine = "\(ack.serverName)" + (ack.mock
                    ? NSLocalizedString("mock_suffix", comment: "") : "")
                self.inViewer = true
                // 订阅必须在握手完成后立即发（对齐 Android：连接线程内 subscribe）
                self.client.send(Requests.subscribe(video: true))
                self.startPing()
                self.lastFrameAt = Date()
                if ack.mock {
                    self.toast = NSLocalizedString("mock_permission_toast", comment: "")
                }
                self.onResumed()
                if self.e2eMode { self.runE2EScript() }
            }
        }
    }

    func disconnect() {
        manualDisconnect = true
        stopTimers()
        client.onClosed = nil
        client.close(reason: nil)
        connected = false
        inViewer = false
        screenInfo = nil
        windows = nil
        zoomed = false
        statusLine = NSLocalizedString("disconnected", comment: "")
    }

    func send(_ dict: [String: Any]) {
        client.send(dict)
    }

    // MARK: 保活与重连（对齐 Android：15s ping / 8s 无帧重订阅 / 2s 重连一次）

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.client.send(Requests.ping())
            // 帧停检测：连接在但 8 秒无帧 → 重发订阅
            if let self = self, self.connected, Date().timeIntervalSince(self.lastFrameAt) > 8 {
                self.client.send(Requests.subscribe(video: true))
            }
        }
    }

    private func stopTimers() {
        pingTimer?.invalidate(); pingTimer = nil
        reconnectTimer?.invalidate(); reconnectTimer = nil
    }

    private func scheduleReconnect() {
        guard !manualDisconnect, resumed else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self = self, !self.connected, !self.connecting, self.resumed else { return }
            self.connect()
        }
    }

    private func onResumed() {
        guard resumed else { return }
        if !connected && !connecting && !manualDisconnect && inViewer {
            connect()
        }
    }

    private func handleClosed(_ reason: String?) {
        guard connected || connecting else { return }
        connected = false
        stopTimers()
        statusLine = NSLocalizedString("closed_fmt", comment: "") + (reason ?? "")
        windows = nil
        scheduleReconnect()
    }

    // MARK: 事件绑定

    private func bindClient() {
        client.onScreenInfo = { [weak self] dict in
            self?.screenInfo = ScreenInfoData(dict: dict)
            self?.lastFrameAt = Date()
        }
        client.onFrame = { [weak self] jpeg in
            guard let self = self else { return }
            self.lastFrameAt = Date()
            self.e2eFrameCount += 1
            if self.e2eMode, self.e2eFrameCount == 1 {
                // e2e 诊断：保存首帧原始 JPEG，验证解码内容
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? jpeg.write(to: dir.appendingPathComponent("frame.jpg"))
            }
            self.frameSink?(jpeg)
        }
        client.onEvent = { [weak self] op, dict in
            self?.handleEvent(op: op, dict: dict)
        }
    }

    private func handleEvent(op: String, dict: [String: Any]) {
        switch op {
        case "windows":
            let list = dict["list"] as? [[String: Any]] ?? []
            windows = list.map { WindowInfoData(dict: $0) }
        case "capture-state":
            if dict["permission"] as? Bool == false {
                toast = NSLocalizedString("no_capture_permission", comment: "")
            }
        case "error":
            if let message = dict["message"] as? String {
                toast = message
                e2eLog("event error: \(message)")
            }
        default:
            break
        }
        e2eLog("event \(op)")
    }

    // MARK: 渲染钩子（ScreenCanvas 注册）

    var frameSink: ((Data) -> Void)?

    func applyZoomState(_ zoomed: Bool) {
        self.zoomed = zoomed
    }

    // MARK: e2e 脚本（模拟器自动化：mock agent 上注入输入与文本，断言事件回带）

    private var e2eFrameCount = 0

    /// 供渲染组件写诊断日志（仅 e2e 模式生效）。
    func e2eLog(_ line: String) {
        guard e2eMode else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = dir.appendingPathComponent("e2e.log")
        let stamp = String(format: "%.2f", Date().timeIntervalSince1970)
        try? "\(stamp) \(line)\n".appendText(to: path)
    }

    private func runE2EScript() {
        e2eLog("connected")
        let steps: [(Double, () -> Void)] = [
            (1.0, { self.e2eLog("frames=\(self.e2eFrameCount)") }),
            (1.5, { self.client.send(Requests.mouse(action: "click", nx: 0.5, ny: 0.5)) }),
            (2.5, { self.client.send(Requests.typeText("你好 MacScreen", submit: false)) }),
            (3.5, { self.client.send(Requests.listWindows()) }),
            (5.0, {
                self.e2eLog("done frames=\(self.e2eFrameCount)")
                self.e2eLog(self.viewHierarchySummary())
            }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.connected else { return }
                step()
            }
        }
    }

    /// 视图层级摘要（诊断白屏/布局问题）：class、frame、UIImageView 的图像尺寸。
    private func viewHierarchySummary() -> String {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let window = window else { return "hierarchy: no key window" }
        var lines: [String] = ["hierarchy:"]
        func walk(_ view: UIView, depth: Int) {
            guard depth <= 8, lines.count < 80 else { return }
            let pad = String(repeating: "  ", count: depth)
            var extra = ""
            if let imageView = view as? UIImageView, let img = imageView.image {
                extra = " img=\(img.size.width)x\(img.size.height)"
            }
            let f = view.frame
            lines.append("\(pad)\(type(of: view)) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height)))\(extra)")
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return lines.joined(separator: "\n")
    }
}

extension String {
    func appendText(to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data(using: .utf8)!)
            try? handle.close()
        } else {
            try? write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 事件数据模型（宽松解析，对齐 Android Messages.kt fromJson）

struct ScreenInfoData {
    let widthPts: Double
    let heightPts: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let mock: Bool

    init(dict: [String: Any]) {
        widthPts = dict["width"] as? Double ?? 0
        heightPts = dict["height"] as? Double ?? 0
        pixelWidth = dict["pixelWidth"] as? Int ?? 0
        pixelHeight = dict["pixelHeight"] as? Int ?? 0
        mock = dict["mock"] as? Bool ?? false
    }
}

struct WindowInfoData: Identifiable {
    let id: Int
    let title: String
    let appName: String
    let onScreen: Bool

    init(dict: [String: Any]) {
        id = dict["id"] as? Int ?? -1
        title = dict["title"] as? String ?? ""
        appName = dict["appName"] as? String ?? ""
        onScreen = dict["onScreen"] as? Bool ?? true
    }

    /// 列表展示文本：title 优先（空白回退 appName，再回退未命名）
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let a = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? NSLocalizedString("window_untitled", comment: "") : a
    }
}
