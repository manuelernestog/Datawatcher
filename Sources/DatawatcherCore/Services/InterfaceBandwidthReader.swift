import Foundation
import Darwin
import SystemConfiguration

/// Instantaneous throughput and byte-delta sample read from the primary physical network interface.
public struct InterfaceBandwidthSample: Equatable, Sendable {
    public let interfaceName: String
    public let bytesInPerSec: Double
    public let bytesOutPerSec: Double
    public let deltaIn: Int64
    public let deltaOut: Int64

    public init(
        interfaceName: String,
        bytesInPerSec: Double,
        bytesOutPerSec: Double,
        deltaIn: Int64,
        deltaOut: Int64
    ) {
        self.interfaceName = interfaceName
        self.bytesInPerSec = bytesInPerSec
        self.bytesOutPerSec = bytesOutPerSec
        self.deltaIn = deltaIn
        self.deltaOut = deltaOut
    }
}

/// Reads cumulative byte counters directly from the macOS kernel via `sysctl(NET_RT_IFLIST2)`
/// for the active physical interface (e.g. `en0`/`en1`), skipping virtual VPN tunnel interfaces
/// such as `utun*` so live speeds are immune to VPN double-counting and closed-socket drops.
public final class InterfaceBandwidthReader: @unchecked Sendable {
    private static let virtualPrefixes = [
        "utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg",
        "lo", "awdl", "llw", "anpi", "bridge", "vmenet", "ap", "feth", "pktap"
    ]

    private var cachedPhysicalInterface: String?
    private var lastInterfaceCheckDate: Date = .distantPast
    private var lastInterface: String?
    private var lastBytesIn: UInt64?
    private var lastBytesOut: UInt64?
    private var lastTimestamp: Date?

    public init() {}

    /// Returns `true` if `name` is a virtual, loopback, tunnel, or internal macOS interface.
    public static func isVirtualInterface(_ name: String) -> Bool {
        virtualPrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// Computes a safe non-negative counter delta, returning `0` on counter drops/resets or
    /// unphysical jumps exceeding `maxDelta`.
    public static func computeDelta(previous: UInt64, current: UInt64, maxDelta: UInt64) -> UInt64 {
        guard current >= previous else { return 0 }
        let delta = current - previous
        return delta <= maxDelta ? delta : 0
    }

    /// Clears all cached baselines and interface state.
    public func reset() {
        cachedPhysicalInterface = nil
        lastInterfaceCheckDate = .distantPast
        lastInterface = nil
        lastBytesIn = nil
        lastBytesOut = nil
        lastTimestamp = nil
    }

    /// Resolves the active physical BSD interface name (e.g. `en0` or `en1`), bypassing VPN tunnels.
    public func primaryPhysicalInterface() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let global = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
               let name = global["PrimaryInterface"] as? String,
               !name.isEmpty,
               !Self.isVirtualInterface(name) {
                return name
            }
        }

        if let setup = SCDynamicStoreCopyValue(nil, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let order = setup["ServiceOrder"] as? [String] {
            for serviceID in order {
                guard let service = SCDynamicStoreCopyValue(
                    nil,
                    "State:/Network/Service/\(serviceID)/IPv4" as CFString
                ) as? [String: Any],
                      service["Router"] != nil,
                      let name = service["InterfaceName"] as? String,
                      !name.isEmpty,
                      !Self.isVirtualInterface(name) else {
                    continue
                }
                return name
            }
        }

        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&interfaceAddresses) == 0 else { return nil }
        defer { freeifaddrs(interfaceAddresses) }

        var pointer = interfaceAddresses
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_POINTOPOINT) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6) else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            if !name.isEmpty && !Self.isVirtualInterface(name) {
                return name
            }
        }

        return nil
    }

    /// Samples the active physical interface and returns live throughput and deltas since the previous call.
    /// Returns a zero-speed baseline sample on the first reading for an interface, or `nil` if no physical
    /// interface is available or `elapsed < 0.2` seconds.
    public func sample(at now: Date = Date()) -> InterfaceBandwidthSample? {
        if cachedPhysicalInterface == nil || now.timeIntervalSince(lastInterfaceCheckDate) >= 4.0 {
            cachedPhysicalInterface = primaryPhysicalInterface()
            lastInterfaceCheckDate = now
        }

        guard let iface = cachedPhysicalInterface,
              let counters = readCounters(interfaceName: iface) else {
            reset()
            return nil
        }

        guard lastInterface == iface,
              let prevIn = lastBytesIn,
              let prevOut = lastBytesOut,
              let prevDate = lastTimestamp else {
            lastInterface = iface
            lastBytesIn = counters.bytesIn
            lastBytesOut = counters.bytesOut
            lastTimestamp = now
            return InterfaceBandwidthSample(
                interfaceName: iface,
                bytesInPerSec: 0,
                bytesOutPerSec: 0,
                deltaIn: 0,
                deltaOut: 0
            )
        }

        let elapsed = now.timeIntervalSince(prevDate)
        guard elapsed >= 0.2 else { return nil }

        let maxBytesPerSec: Double
        if counters.baudrate > 0 && counters.baudrate < UInt64(UInt32.max) {
            maxBytesPerSec = (Double(counters.baudrate) / 8.0) * 1.5
        } else {
            maxBytesPerSec = 1_250_000_000.0 // 10 Gbps fallback when link baudrate is unknown
        }
        let maxDelta = UInt64(max(1.0, maxBytesPerSec * elapsed))

        let dIn = Self.computeDelta(previous: prevIn, current: counters.bytesIn, maxDelta: maxDelta)
        let dOut = Self.computeDelta(previous: prevOut, current: counters.bytesOut, maxDelta: maxDelta)

        lastBytesIn = counters.bytesIn
        lastBytesOut = counters.bytesOut
        lastTimestamp = now

        return InterfaceBandwidthSample(
            interfaceName: iface,
            bytesInPerSec: Double(dIn) / elapsed,
            bytesOutPerSec: Double(dOut) / elapsed,
            deltaIn: Int64(clamping: dIn),
            deltaOut: Int64(clamping: dOut)
        )
    }

    private func readCounters(interfaceName: String) -> (bytesIn: UInt64, bytesOut: UInt64, baudrate: UInt64)? {
        let index = if_nametoindex(interfaceName)
        guard index != 0 else { return nil }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        var offset = 0
        let msgHeaderSize = MemoryLayout<if_msghdr>.size
        let msgHeader2Size = MemoryLayout<if_msghdr2>.size

        while offset + msgHeaderSize <= size {
            var header = if_msghdr()
            buffer.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                _ = memcpy(&header, base.advanced(by: offset), msgHeaderSize)
            }

            let msgLen = Int(header.ifm_msglen)
            guard msgLen > 0 else { return nil }

            if Int32(header.ifm_type) == RTM_IFINFO2, offset + msgHeader2Size <= size {
                var header2 = if_msghdr2()
                buffer.withUnsafeBytes { src in
                    guard let base = src.baseAddress else { return }
                    _ = memcpy(&header2, base.advanced(by: offset), msgHeader2Size)
                }
                if UInt32(header2.ifm_index) == index {
                    return (
                        bytesIn: UInt64(header2.ifm_data.ifi_ibytes),
                        bytesOut: UInt64(header2.ifm_data.ifi_obytes),
                        baudrate: UInt64(header2.ifm_data.ifi_baudrate)
                    )
                }
            }

            offset += msgLen
        }

        return nil
    }
}

