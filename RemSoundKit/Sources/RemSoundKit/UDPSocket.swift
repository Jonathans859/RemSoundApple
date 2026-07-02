import Darwin
import Foundation

/// IPv4 UDP endpoint. The whole RemSound protocol is IPv4 (matching the Windows app's
/// AF_INET sockets), so we store the raw network-order address + host-order port.
public struct UDPEndpoint: Hashable, Sendable, CustomStringConvertible {
    /// IPv4 address in network byte order.
    public let address: UInt32
    /// Port in host byte order.
    public let port: UInt16

    public init(address: UInt32, port: UInt16) {
        self.address = address
        self.port = port
    }

    public init?(host: String, port: UInt16) {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        self.address = addr.s_addr
        self.port = port
    }

    public var addressString: String {
        var addr = in_addr(s_addr: address)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    public var description: String { "\(addressString):\(port)" }

    var sockaddr: sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = in_addr(s_addr: address)
        return sa
    }

    /// Resolves a hostname or dotted-quad to IPv4 endpoints (DNS for relay hostnames,
    /// MagicDNS names, etc.). Blocking — call off the main thread.
    public static func resolve(host: String, port: UInt16) -> [UDPEndpoint] {
        if let direct = UDPEndpoint(host: host, port: port) { return [direct] }
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var endpoints: [UDPEndpoint] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if info.pointee.ai_family == AF_INET, let sa = info.pointee.ai_addr {
                let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ep = UDPEndpoint(address: sin.sin_addr.s_addr, port: port)
                if !endpoints.contains(ep) { endpoints.append(ep) }
            }
            cursor = info.pointee.ai_next
        }
        return endpoints
    }
}

/// Minimal blocking-recv UDP socket with a dedicated drain thread, mirroring the Windows
/// `NetworkListener` design: one fixed receive buffer reused across calls, packets handed up
/// as (buffer, length, remote) — the callback must copy anything it keeps.
public final class UDPSocket {
    public typealias PacketHandler = (_ buffer: [UInt8], _ length: Int, _ remote: UDPEndpoint) -> Void

    private var fd: Int32 = -1
    private var thread: Thread?
    private let onPacket: PacketHandler
    private let onDiagnostic: ((String) -> Void)?
    private let lock = NSLock()

    public init(onPacket: @escaping PacketHandler, onDiagnostic: ((String) -> Void)? = nil) {
        self.onPacket = onPacket
        self.onDiagnostic = onDiagnostic
    }

    /// The locally-bound port (useful when binding port 0).
    public private(set) var boundPort: UInt16 = 0

    /// Bind and start the receive thread. `port` 0 lets the OS pick.
    /// Broadcast permission is needed to SEND broadcast announcements (discovery).
    public func start(port: UInt16, enableBroadcast: Bool = false, reuseAddress: Bool = true) throws {
        stop()
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var one: Int32 = 1
        if reuseAddress {
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        if enableBroadcast {
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        // 1 MB kernel receive buffer — same rationale as the Windows receiver: ride out
        // short render-thread or scheduler stalls without the kernel dropping datagrams.
        var bufSize: Int32 = 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &sa) { ptr in
            ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(sock)
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }

        // Recover the actual bound port (when asked for 0).
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { saPtr in
                _ = getsockname(sock, saPtr, &boundLen)
            }
        }
        boundPort = UInt16(bigEndian: bound.sin_port)

        lock.lock()
        fd = sock
        lock.unlock()

        let receiveThread = Thread { [weak self] in self?.receiveLoop(socket: sock) }
        receiveThread.name = "RemSound.UDPReceive"
        // Network drain feeds the audio path; raise priority above default UI work.
        receiveThread.qualityOfService = .userInteractive
        receiveThread.start()
        thread = receiveThread
        onDiagnostic?("UDP socket bound to :\(boundPort)")
    }

    public func stop() {
        lock.lock()
        let sock = fd
        fd = -1
        lock.unlock()
        if sock >= 0 {
            close(sock) // unblocks the recvfrom in the receive thread
        }
        thread = nil
    }

    deinit { stop() }

    /// Fire-and-forget UDP send. Returns true when the datagram was handed to the kernel.
    @discardableResult
    public func send(_ data: [UInt8], count: Int? = nil, to endpoint: UDPEndpoint) -> Bool {
        lock.lock()
        let sock = fd
        lock.unlock()
        guard sock >= 0 else { return false }
        var sa = endpoint.sockaddr
        let length = count ?? data.count
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &sa) { ptr in
                ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { saPtr in
                    sendto(sock, bytes.baseAddress, length, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == length
    }

    @discardableResult
    public func send(_ data: Data, to endpoint: UDPEndpoint) -> Bool {
        send([UInt8](data), to: endpoint)
    }

    private func receiveLoop(socket sock: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while true {
            let received = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { saPtr in
                        recvfrom(sock, bytes.baseAddress, bytes.count, 0, saPtr, &fromLen)
                    }
                }
            }
            if received <= 0 {
                // Socket closed (stop()) or fatal error — exit the thread.
                if received < 0 && (errno == EINTR) { continue }
                break
            }
            let remote = UDPEndpoint(address: from.sin_addr.s_addr, port: UInt16(bigEndian: from.sin_port))
            onPacket(buffer, received, remote)
        }
    }
}

/// Local IPv4 interface enumeration — used for subnet broadcast addresses (discovery) and
/// self-identification.
public enum NetworkInterfaces {
    /// Subnet-directed broadcast addresses of all up, non-loopback IPv4 interfaces, plus the
    /// limited broadcast 255.255.255.255.
    public static func broadcastAddresses(port: UInt16) -> [UDPEndpoint] {
        var result: Set<UDPEndpoint> = [UDPEndpoint(address: INADDR_BROADCAST.bigEndian, port: port)]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return Array(result) }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let maskPtr = ifa.pointee.ifa_netmask else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let broadcast = sin.sin_addr.s_addr | ~mask.sin_addr.s_addr
            result.insert(UDPEndpoint(address: broadcast, port: port))
        }
        return Array(result)
    }

    /// Local (non-loopback) IPv4 addresses, network byte order — used to ignore our own
    /// discovery announcements echoed back by the network.
    public static func localAddresses() -> Set<UInt32> {
        var result: Set<UInt32> = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return result }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            result.insert(sin.sin_addr.s_addr)
        }
        return result
    }
}
