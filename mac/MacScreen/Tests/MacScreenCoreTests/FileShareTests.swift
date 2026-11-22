import XCTest
import Network
@testable import MacScreenCore

final class FileShareTests: XCTestCase {

    // MARK: 默认产物解析

    func testResolveDefaultShareFileWalksUpParents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-test-\(UUID().uuidString)")
        let exeDir = root.appendingPathComponent("mac/MacScreen/.build/debug")
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
        let apk = root.appendingPathComponent("dist/LAN-Mac-Controller-debug.apk")
        try FileManager.default.createDirectory(at: apk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x50, 0x4B]).write(to: apk)

        let exe = exeDir.appendingPathComponent("MacScreenAgent").path
        XCTAssertEqual(FileShareServer.resolveDefaultShareFile(executablePath: exe)?.path, apk.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testResolveDefaultShareFileLegacyApkName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-test-\(UUID().uuidString)")
        let exeDir = root.appendingPathComponent("mac/MacScreen/.build/debug")
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
        // 旧产物名仍应被兜底识别
        let apk = root.appendingPathComponent("dist/MacScreenClient-debug.apk")
        try FileManager.default.createDirectory(at: apk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x50, 0x4B]).write(to: apk)

        let exe = exeDir.appendingPathComponent("MacScreenAgent").path
        XCTAssertEqual(FileShareServer.resolveDefaultShareFile(executablePath: exe)?.path, apk.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testResolveDefaultShareFileFallsBackToAndroidOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-test-\(UUID().uuidString)")
        let exeDir = root.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
        let apk = root.appendingPathComponent(
            "android/MacScreenClient/app/build/outputs/apk/debug/app-debug.apk")
        try FileManager.default.createDirectory(at: apk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x50, 0x4B]).write(to: apk)

        let exe = exeDir.appendingPathComponent("MacScreenAgent").path
        XCTAssertEqual(FileShareServer.resolveDefaultShareFile(executablePath: exe)?.path, apk.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testResolveDefaultShareFileReturnsNilWhenAbsent() {
        let deep = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-empty-\(UUID().uuidString)/a/b/c")
        XCTAssertNil(FileShareServer.resolveDefaultShareFile(
            executablePath: deep.appendingPathComponent("agent").path))
        XCTAssertNil(FileShareServer.resolveDefaultShareFile(executablePath: nil))
    }

    // MARK: 纯函数

    func testContentDispositionSupportsChinese() {
        XCTAssertEqual(
            FileShareServer.contentDisposition("报表 2026.pdf"),
            "attachment; filename=\"__ 2026.pdf\"; filename*=UTF-8''%E6%8A%A5%E8%A1%A8%202026.pdf")
        XCTAssertEqual(
            FileShareServer.contentDisposition("plain.apk"),
            "attachment; filename=\"plain.apk\"; filename*=UTF-8''plain.apk")
    }

    func testResponseHead() {
        let head = String(data: FileShareServer.responseHead(
            status: "200 OK", contentType: "application/octet-stream",
            contentLength: 123, filename: "a.apk"), encoding: .utf8)!
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Content-Length: 123\r\n"))
        XCTAssertTrue(head.contains("Content-Disposition: attachment"))
        XCTAssertTrue(head.hasSuffix("Connection: close\r\n\r\n"))

        let noFile = String(data: FileShareServer.responseHead(
            status: "404 Not Found", contentType: "text/plain; charset=utf-8",
            contentLength: 0, filename: nil), encoding: .utf8)!
        XCTAssertTrue(noFile.hasPrefix("HTTP/1.1 404"))
        XCTAssertFalse(noFile.contains("Content-Disposition"))
    }

    // MARK: HTTP 集成（回环真实 TCP）

    private func makeTempFile(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-file-\(UUID().uuidString).bin")
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: url)
        return url
    }

    /// 极简 HTTP 客户端：发送请求，读到连接关闭为止，返回 (响应头, 响应体)。
    private func httpExchange(port: UInt16, request: String) throws -> (String, Data) {
        let lock = NSLock()
        final class Box {
            var data = Data()
            var done = false
        }
        let box = Box()
        let group = DispatchGroup()
        group.enter()

        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        func finish() {
            lock.lock()
            let first = !box.done
            box.done = true
            lock.unlock()
            if first { group.leave() }
        }
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                lock.lock()
                if let d = data { box.data.append(d) }
                let ended = isComplete || data == nil
                lock.unlock()
                if ended { finish() } else { pump() }
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: request.data(using: .utf8), completion: .contentProcessed { _ in })
                pump()
            case .cancelled, .failed:
                finish()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "test.http.client.\(UUID().uuidString)"))
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "HTTP 交换超时")
        conn.cancel()

        lock.lock()
        defer { lock.unlock() }
        let data = box.data
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(data: data.subdata(in: data.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
            let body = data.subdata(in: range.upperBound..<data.endIndex)
            return (head, body)
        }
        return (String(data: data, encoding: .utf8) ?? "", Data())
    }

    func testDownloadOverLoopback() throws {
        let file = try makeTempFile(size: 300_000)   // 覆盖两个 256KB 分块
        defer { try? FileManager.default.removeItem(at: file) }
        let server = FileShareServer(port: 0, lanGuard: LANGuard())
        XCTAssertEqual(server.setFile(file), 300_000)
        try server.start()
        XCTAssertGreaterThan(server.boundPort, 0)
        defer { server.stop() }

        // GET（带查询串，应忽略 query）
        let (head, body) = try httpExchange(
            port: server.boundPort,
            request: "GET \(FileShareServer.path)?x=1 HTTP/1.1\r\nHost: t\r\n\r\n")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK"), head)
        XCTAssertTrue(head.contains("Content-Length: 300000"), head)
        XCTAssertTrue(head.contains("Content-Type: application/octet-stream"), head)
        XCTAssertTrue(head.contains("filename*=UTF-8''"), head)
        XCTAssertEqual(body, try Data(contentsOf: file))

        // HEAD：只有头，无响应体
        let (head2, body2) = try httpExchange(
            port: server.boundPort,
            request: "HEAD \(FileShareServer.path) HTTP/1.1\r\nHost: t\r\n\r\n")
        XCTAssertTrue(head2.hasPrefix("HTTP/1.1 200 OK"), head2)
        XCTAssertTrue(body2.isEmpty)

        // 未知路径 404
        let (head3, _) = try httpExchange(
            port: server.boundPort, request: "GET /nope HTTP/1.1\r\nHost: t\r\n\r\n")
        XCTAssertTrue(head3.hasPrefix("HTTP/1.1 404"), head3)
    }

    func testStartFailsWithoutFile() {
        let server = FileShareServer(port: 0, lanGuard: LANGuard())
        XCTAssertThrowsError(try server.start())
    }
}
