import Foundation
import Darwin

struct NetworkSnapshot: Sendable {
    var downloadRate: Double = 0
    var uploadRate: Double = 0
    var sessionReceived: UInt64 = 0
    var sessionSent: UInt64 = 0

    static let zero = NetworkSnapshot()
}

final class NetworkSampler {
    private var previous: (rx: UInt64, tx: UInt64, time: UInt64)?
    private var baseline: (rx: UInt64, tx: UInt64)?

    func sample() -> NetworkSnapshot {
        let (rx, tx) = Self.interfaceTotals()
        let now = DispatchTime.now().uptimeNanoseconds
        var snapshot = NetworkSnapshot()

        if baseline == nil { baseline = (rx, tx) }
        if let baseline {
            snapshot.sessionReceived = rx >= baseline.rx ? rx - baseline.rx : 0
            snapshot.sessionSent = tx >= baseline.tx ? tx - baseline.tx : 0
        }
        if let previous {
            let seconds = Double(now - previous.time) / 1_000_000_000
            if seconds > 0 {
                snapshot.downloadRate = rx >= previous.rx ? Double(rx - previous.rx) / seconds : 0
                snapshot.uploadRate = tx >= previous.tx ? Double(tx - previous.tx) / seconds : 0
            }
        }
        previous = (rx, tx, now)
        return snapshot
    }

    /// Sums 64-bit byte counters for physical (Ethernet-type) interfaces.
    /// Skips loopback and tunnels, which would double-count VPN traffic.
    static func interfaceTotals() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        let ethernetType: UInt8 = 0x06 // IFT_ETHER (Wi-Fi reports as Ethernet too)
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        let end = length
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= end {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= end {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0, message.ifm_data.ifi_type == ethernetType {
                        rx += message.ifm_data.ifi_ibytes
                        tx += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }
}
