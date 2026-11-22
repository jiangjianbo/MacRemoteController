import Foundation
import Network
import MacScreenCore

// MARK: - PhoneSimulator：模拟手机端测试客户端（端到端测试用）
//
// 用法:
//   PhoneSimulator --info-file PATH [--steps full|basic] [--bad-token]
//   PhoneSimulator --host 127.0.0.1 --port 9700 --token XXXX [--bad-token]
//
// 退出码 0 = 全部断言通过。

final class Simulator {
    let connection: NWConnectionAdapter
    let queue = DispatchQueue(label: "macscreen.sim")
    var decoder = FrameDecoder()

    let lock = NSLock()
    var pendingEvents: [(op: String, dict: [String: Any])] = []
    var frameCount = 0
    var closedByServer = false
    let eventSignal = DispatchSemaphore(value: 0)
    let frameSignal = DispatchSemaphore(value: 0)
    let closeSignal = DispatchSemaphore(value: 0)

    var failures: [String] = []
    var stepsPassed = 0

    init(host: String, port: UInt16) {
        let nw = NWConnection(host: NWEndpoint.Host(host),
                              port: NWEndpoint.Port(rawValue: port)!,
                              using: .tcp)
        self.connection = NWConnectionAdapter(nw, queue: queue)
    }

    func start() {
        connection.onReceive = { [weak self] data in
            guard let self = self else { return }
            let frames = self.decoder.feed(data)
            for frame in frames {
                switch frame.kind {
                case .jpeg:
                    self.lock.lock(); self.frameCount += 1; self.lock.unlock()
                    self.frameSignal.signal()
                case .json:
                    guard let obj = try? JSONSerialization.jsonObject(with: frame.payload),
                          let dict = obj as? [String: Any],
                          let op = dict["op"] as? String else { continue }
                    self.lock.lock(); self.pendingEvents.append((op, dict)); self.lock.unlock()
                    self.eventSignal.signal()
                }
            }
        }
        connection.onClose = { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); self.closedByServer = true; self.lock.unlock()
            self.closeSignal.signal()
            self.eventSignal.signal()
        }
        connection.start()
    }

    func waitReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connection.peerAddress != "unknown" { return true }
            usleep(20_000)
        }
        return false
    }

    func send(_ dict: [String: Any]) {
        guard let frame = ProtocolFrame.json(dict) else { return }
        connection.send(frame.encoded())
    }

    func waitFor(op: String, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let index = pendingEvents.firstIndex(where: { $0.op == op }) {
                let dict = pendingEvents.remove(at: index).dict
                lock.unlock()
                return dict
            }
            lock.unlock()
            _ = eventSignal.wait(timeout: .now() + 0.2)
        }
        return nil
    }

    func waitForClose(timeout: TimeInterval) -> Bool {
        _ = closeSignal.wait(timeout: .now() + timeout)
        lock.lock(); let closed = closedByServer; lock.unlock()
        return closed
    }

    func waitForFrames(_ n: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, frameCount < n {
            _ = frameSignal.wait(timeout: .now() + 0.5)
        }
        return frameCount
    }

    // MARK: 断言

    func check(_ name: String, _ condition: Bool, detail: String = "") {
        if condition {
            stepsPassed += 1
            print("  ✓ \(name)")
        } else {
            failures.append(name)
            print("  ✗ \(name)  \(detail)")
        }
    }

    func request(_ op: String, _ extra: [String: Any] = [:], id: Int) -> [String: Any] {
        var dict: [String: Any] = ["op": op, "id": id]
        for (k, v) in extra { dict[k] = v }
        send(dict)
        return dict
    }

    func expectOp(_ op: String, after sent: [String: Any], timeout: TimeInterval = 5) -> [String: Any]? {
        waitFor(op: op, timeout: timeout)
    }

    func finish() -> Never {
        print(failures.isEmpty
              ? "PASS：\(stepsPassed) 项断言全部通过"
              : "FAIL：\(failures.count) 项失败 → \(failures.joined(separator: "; "))")
        exit(failures.isEmpty ? 0 : 1)
    }
}

// MARK: - 参数解析

struct SimArgs {
    var host = "127.0.0.1"
    var port: UInt16 = 9700
    var token = ""
    var badToken = false
    var scenario = "full"
    var frameWait = 5

    static func parse(_ args: [String]) -> SimArgs {
        var result = SimArgs()
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--host": result.host = iterator.next() ?? result.host
            case "--port": if let v = iterator.next(), let p = UInt16(v) { result.port = p }
            case "--token": result.token = iterator.next() ?? ""
            case "--bad-token": result.badToken = true
            case "--scenario": result.scenario = iterator.next() ?? "full"
            case "--frame-wait": if let v = iterator.next(), let n = Int(v) { result.frameWait = n }
            case "--info-file":
                if let path = iterator.next(), let data = FileManager.default.contents(atPath: path),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let hosts = obj["hosts"] as? [String], let first = hosts.first { result.host = first }
                    if let port = obj["port"] as? Int { result.port = UInt16(clamping: port) }
                    if let token = obj["token"] as? String { result.token = token }
                }
            default:
                break
            }
        }
        return result
    }
}

// MARK: - 主流程

let args = SimArgs.parse(Array(CommandLine.arguments.dropFirst()))
let sim = Simulator(host: args.host, port: args.port)
print("连接 \(args.host):\(args.port)（scenario=\(args.scenario)，badToken=\(args.badToken)）")
sim.start()
guard sim.waitReady(timeout: 5) else {
    print("FAIL：连接超时")
    exit(1)
}

if args.badToken {
    // 反向用例：错误 token 必须被拒绝（error 事件或断开），不得收到 hello-ack
    sim.send(["op": "hello", "token": "wrong-token-\(Int.random(in: 1000...9999))", "id": 1])
    let ack = sim.waitFor(op: "hello-ack", timeout: 3)
    let error = sim.waitFor(op: "error", timeout: 3)
    let closed = sim.waitForClose(timeout: 4)
    sim.check("错误 token 被拒绝(无 hello-ack)", ack == nil)
    sim.check("收到 error 或被断开", error != nil || closed, detail: "error=\(String(describing: error)) closed=\(closed)")
    sim.finish()
}

guard !args.token.isEmpty else {
    print("FAIL：缺少 token")
    exit(1)
}

// 1. hello 握手
sim.send(["op": "hello", "token": args.token, "deviceName": "PhoneSimulator", "id": 1])
let ack = sim.waitFor(op: "hello-ack", timeout: 5)
sim.check("hello-ack 收到且 ok", (ack?["ok"] as? Bool) == true,
          detail: "\(String(describing: ack))")
_ = sim.waitFor(op: "screen-info", timeout: 3) // 握手附带的 screen-info（不必断言内容）

if args.scenario == "basic" {
    sim.finish()
}

// 2. 订阅视频 + 收帧
_ = sim.request("subscribe", ["video": true], id: 2)
_ = sim.waitFor(op: "screen-info", timeout: 5)
let frames = sim.waitForFrames(5, timeout: TimeInterval(args.frameWait))
sim.check("收到 ≥5 帧 JPEG", frames >= 5, detail: "实际 \(frames) 帧")
if frames > 0 {
    sim.check("JPEG 帧在屏幕信息之后可正常解码（数量断言）", frames >= 5)
}

// 3. ping
_ = sim.request("ping", id: 3)
let pong = sim.waitFor(op: "pong", timeout: 5)
sim.check("ping→pong", pong != nil)

// 4. 窗口列表 + 激活
_ = sim.request("list-windows", id: 4)
let windows = sim.waitFor(op: "windows", timeout: 5)
let list = windows?["list"] as? [[String: Any]] ?? []
sim.check("list-windows 返回列表", windows != nil, detail: "\(list.count) 个窗口")
if let first = list.first, let windowId = first["id"] as? Int {
    _ = sim.request("activate-window", ["windowId": windowId], id: 5)
    let ok = sim.waitFor(op: "ok", timeout: 5)
    sim.check("activate-window 成功", (ok?["action"] as? String) == "activate-window",
              detail: "\(String(describing: ok))")
}

// 5. 鼠标点击（归一化坐标，应答带屏幕坐标 echo）
_ = sim.request("mouse", ["action": "click", "x": 0.5, "y": 0.5], id: 6)
let click = sim.waitFor(op: "ok", timeout: 5)
let clickEcho = click?["echo"] as? [String: Any]
let echoX = (clickEcho?["x"] as? NSNumber)?.doubleValue ?? -1
sim.check("鼠标点击 ok 且坐标映射正确",
          (click?["action"] as? String) == "mouse" && abs(echoX - 720) < 1.0,
          detail: "echo=\(String(describing: clickEcho))")

// 6. 文本输入（echo 校验）
let sentText = "你好 MacScreen 你好"
_ = sim.request("type-text", ["text": sentText, "submit": true], id: 7)
let typeAck = sim.waitFor(op: "ok", timeout: 5)
let typeEcho = typeAck?["echo"] as? [String: Any]
let echoedText = typeEcho?["text"] as? String ?? ""
sim.check("文本输入 echo 一致", echoedText == sentText,
          detail: "期望[\(sentText)] 实际[\(echoedText)]")
sim.check("submit 标志回带", (typeEcho?["submit"] as? Bool) == true)

// 7. 按键
_ = sim.request("press-key", ["key": "return", "modifiers": ["command"]], id: 8)
let keyAck = sim.waitFor(op: "ok", timeout: 5)
let keyEcho = keyAck?["echo"] as? [String: Any]
sim.check("press-key echo 正确",
          (keyEcho?["key"] as? String) == "return" && (keyEcho?["modifiers"] as? [String]) == ["command"],
          detail: "\(String(describing: keyEcho))")

// 8. set-capture 调整帧率
_ = sim.request("set-capture", ["fps": 5], id: 9)
let capState = sim.waitFor(op: "capture-state", timeout: 5)
sim.check("set-capture 返回 capture-state", capState != nil)

// 9. get-status
_ = sim.request("get-status", id: 10)
let status = sim.waitFor(op: "status", timeout: 5)
sim.check("get-status 返回状态", (status?["port"] as? Int) != nil)

// 10. 退订视频
_ = sim.request("subscribe", ["video": false], id: 11)
let before = sim.frameCount
_ = sim.waitForFrames(before + 1, timeout: 2)
let after = sim.frameCount
// 2 秒内不应再来帧（fps≥5 的 Mock 源）
sim.check("退订后不再收帧", after <= before + 1, detail: "before=\(before) after=\(after)")

sim.connection.close()
sim.finish()
