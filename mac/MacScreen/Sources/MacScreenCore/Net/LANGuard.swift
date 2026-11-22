import Foundation
import Darwin

/// 工具：从对端地址字符串提取主机部分。
/// 支持 "1.2.3.4:5678"、"[fe80::1%en0]:5678"、"fe80::1%en0"、"1.2.3.4" 等形式。
public enum AddressUtils {
    public static func hostOnly(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespaces)
        // [v6]:port
        if text.hasPrefix("[") {
            if let end = text.firstIndex(of: "]") {
                return String(text[text.index(after: text.startIndex) ..< end])
            }
        }
        // host:port（仅当只有一个冒号时才视为 v4 host:port；否则可能是裸 v6）
        if text.filter({ $0 == ":" }).count == 1 {
            let parts = text.split(separator: ":")
            if parts.count == 2 { text = String(parts[0]) }
        }
        // 去掉 zone（fe80::1%en0）
        if let pct = text.firstIndex(of: "%") {
            text = String(text[..<pct])
        }
        return text
    }

    /// 点分十进制 → UInt32（主机字节序）。解析失败返回 nil。
    public static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard let byte = UInt32(p), byte <= 255 else { return nil }
            value = (value << 8) | byte
        }
        return value
    }

    public static func formatIPv4(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }

    /// IPv6 字符串 → 16 字节数组。失败返回 nil。
    public static func parseIPv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        let result = s.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}

/// IPv4 子网（CIDR）。
public struct IPv4Subnet: Equatable {
    public let address: UInt32   // 接口原始地址（主机字节序）
    public let network: UInt32   // 已按掩码归一化的网络地址
    public let prefix: Int

    public init?(address: String, prefix: Int) {
        guard let ip = AddressUtils.parseIPv4(address), prefix >= 0, prefix <= 32 else { return nil }
        self.address = ip
        self.network = ip & Self.mask(prefix)
        self.prefix = prefix
    }

    public init(network: UInt32, prefix: Int) {
        let m = Self.mask(prefix)
        self.address = network          // 原始接口地址（不掩码）
        self.network = network & m      // 归一化网络地址
        self.prefix = prefix
    }

    public static func mask(_ prefix: Int) -> UInt32 {
        prefix <= 0 ? 0 : (prefix >= 32 ? ~UInt32(0) : ~UInt32(0) << (32 - prefix))
    }

    public func contains(_ ip: UInt32) -> Bool {
        ip & Self.mask(prefix) == network
    }
}

/// 本机接口信息快照（可注入，便于测试）。
public struct LocalInterfaces: Equatable {
    public var v4: [IPv4Subnet]
    public var v6Prefixes: [[[UInt8]]]   // 每个全局/ULA v6 地址的完整 16 字节（按 /64 比较）

    public init(v4: [IPv4Subnet] = [], v6Prefixes: [[[UInt8]]] = []) {
        self.v4 = v4
        self.v6Prefixes = v6Prefixes
    }
}

/// 局域网守卫：只接受 同网段/回环 连接，拒绝一切非本机子网的地址（含公网）。
public final class LANGuard {
    public typealias Provider = () -> LocalInterfaces

    let provider: Provider

    public init(provider: @escaping Provider = LANGuard.systemInterfaces) {
        self.provider = provider
    }

    /// 判断对端是否允许连接。
    public func isAllowed(_ peerAddress: String) -> Bool {
        let host = AddressUtils.hostOnly(peerAddress)
        guard !host.isEmpty else { return false }

        // 回环总是允许（本机测试/PhoneSimulator）
        if host == "::1" || host.hasPrefix("127.") { return true }

        // IPv4
        if let ip = AddressUtils.parseIPv4(host) {
            // 仅允许 RFC1918 私网；公网一律拒绝
            guard Self.isPrivateIPv4(ip) else { return false }
            let ifs = provider()
            return ifs.v4.contains { $0.contains(ip) }
        }

        // IPv6
        if host.contains(":"), let bytes = AddressUtils.parseIPv6(host) {
            // 链路本地 fe80::/10：同一二层链路，允许
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
            // 其余（全局/ULA）：必须与本机某接口同 /64
            let ifs = provider()
            for prefixList in ifs.v6Prefixes {
                for candidate in prefixList where Self.samePrefix64(bytes, candidate) {
                    return true
                }
            }
            return false
        }

        return false
    }

    /// RFC1918: 10/8、172.16/12、192.168/16
    public static func isPrivateIPv4(_ ip: UInt32) -> Bool {
        let top = ip >> 24
        if top == 10 { return true }
        if top == 172 {
            let second = (ip >> 16) & 0xFF
            return second >= 16 && second <= 31
        }
        if top == 192 && ((ip >> 16) & 0xFF) == 168 { return true }
        return false
    }

    /// 比较两个 IPv6 地址前 64 位是否一致。
    public static func samePrefix64(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == 16, b.count == 16 else { return false }
        for i in 0..<8 where a[i] != b[i] { return false }
        return true
    }

    /// 读取本机接口（getifaddrs）。
    public static func systemInterfaces() -> LocalInterfaces {
        var result = LocalInterfaces()
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return result }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr {
                let family = sa.pointee.sa_family
                if family == UInt8(AF_INET) {
                    let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
                    let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
                    var mask: UInt32 = 0
                    if let nm = ifa.ifa_netmask {
                        let m = UnsafeRawPointer(nm).assumingMemoryBound(to: sockaddr_in.self).pointee
                        mask = UInt32(bigEndian: m.sin_addr.s_addr)
                    }
                    let prefix = mask == 0 ? 0 : Self.prefixLength(of: mask)
                    result.v4.append(IPv4Subnet(network: ip, prefix: prefix))
                } else if family == UInt8(AF_INET6) {
                    let sin6 = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in6.self).pointee
                    let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                    // 只记录非链路本地的地址（链路本地默认放行，不需要接口表）
                    if !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
                        result.v6Prefixes.append([bytes])
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }

    static func prefixLength(of mask: UInt32) -> Int {
        mask.nonzeroBitCount
    }

    /// 本机所有 IPv4 地址字符串（用于 agent-info / QR 内容）。
    public static func localIPv4Addresses() -> [String] {
        systemInterfaces().v4
            .filter { $0.prefix > 0 && $0.prefix < 32 }   // 排除 0.0.0.0
            .map { AddressUtils.formatIPv4($0.address) }  // 原始接口地址
            .filter { !$0.hasPrefix("127.") }
    }
}
