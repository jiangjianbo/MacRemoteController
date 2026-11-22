import Foundation
import Network

/// Bonjour 发现：浏览 Mac agent 广播的 _macscreen._tcp（对齐 Android NsdDiscovery）。
/// NWBrowser 只给服务名，真实 host:port 需用临时 NWConnection resolve。
final class DiscoveryBrowser: ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: String        // 服务名去重
        let name: String
        let host: String
        let port: Int
    }

    @Published var services: [Found] = []
    @Published var error: String?

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_macscreen._tcp", domain: "local."), using: params)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let names = Set(results.compactMap { result -> String? in
                    if case let .service(name, _, _, _) = result.endpoint { return name }
                    return nil
                })
                // 上下线同步
                self.services.removeAll { !names.contains($0.id) }
                for name in names where !self.services.contains(where: { $0.id == name }) {
                    self.services.append(Found(id: name, name: name, host: "", port: 0))
                    self.resolve(name: name)
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                DispatchQueue.main.async { self?.error = e.localizedDescription }
            }
        }
        browser.start(queue: DispatchQueue(label: "macscreen.browse"))
    }

    private func resolve(name: String) {
        guard resolvers[name] == nil else { return }
        let endpoint = NWEndpoint.service(name: name, type: "_macscreen._tcp",
                                          domain: "local.", interface: nil)
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let hostStr: String
                let port: UInt16
                if let path = conn.currentPath, let remote = path.remoteEndpoint,
                   case let .hostPort(host, p) = remote {
                    hostStr = Self.hostString(host)
                    port = p.rawValue
                } else {
                    hostStr = ""
                    port = 0
                }
                DispatchQueue.main.async {
                    self?.upsert(Found(id: name, name: name, host: hostStr, port: Int(port)))
                    conn.cancel()
                }
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.resolvers[name] = nil }
                conn.stateUpdateHandler = nil
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "macscreen.resolve"))
    }

    /// IPv4 直接给地址；IPv6 link-local 会带 %en0 接口后缀，剥掉（agent 端 LANGuard 接受链路本地）。
    static func hostString(_ host: NWEndpoint.Host) -> String {
        let s: String
        switch host {
        case .ipv4(let v4): s = "\(v4)"
        case .ipv6(let v6): s = "\(v6)"
        case .name(let n, _): s = n
        @unknown default: s = ""
        }
        return s.split(separator: "%").first.map(String.init) ?? s
    }

    private func upsert(_ f: Found) {
        guard !f.host.isEmpty else { return }
        if let idx = services.firstIndex(where: { $0.id == f.id }) {
            services[idx] = f
        } else {
            services.append(f)
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for conn in resolvers.values { conn.cancel() }
        resolvers.removeAll()
    }
}
