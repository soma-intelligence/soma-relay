import CryptoKit
import Foundation

/// Mesh router used with the mock core (the real core ships its own `MeshRouter`).
/// Frame = 0x46 magic, hops_left (u8), id (16), index (u16 BE), count (u16 BE), payload.
/// Dedup on (id, index), TTL in `hops_left`, never sent back on the ingress link (the transport
/// excludes `excludeLink`). Reassembly caps: 128 assemblies, 30 s, 1 MiB.
nonisolated final class SwiftMeshRouter: MeshRouterAPI {
    static let initialHops: UInt8 = 7
    private static let header = 22

    private var seen: [Data: Int64] = [:]
    private var assemblies: [Data: Assembly] = [:]

    private struct Assembly {
        var parts: [Int: Data]
        var count: Int
        var started: Int64
        var bytes: Int
    }

    func framesFor(envelope: Data, mtu: UInt32) -> [Data] {
        let id = Data(SHA256.hash(data: envelope)).prefix(16)
        let chunk = max(64, Int(mtu) - Self.header)
        let count = max(1, (envelope.count + chunk - 1) / chunk)
        var frames: [Data] = []
        let now = Clock.nowMs
        for index in 0..<count {
            let start = index * chunk
            let part = envelope.subdata(in: (envelope.startIndex + start)..<(envelope.startIndex + min(envelope.count, start + chunk)))
            var frame = Data([0x46, Self.initialHops])
            frame.append(id)
            frame.append(contentsOf: [UInt8(index >> 8), UInt8(index & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF)])
            frame.append(part)
            frames.append(frame)
            seen[key(id, index)] = now
        }
        prune(now)
        return frames
    }

    func onFrame(_ frame: Data, fromLink: UInt32, nowMs: Int64) -> MeshResult {
        let f = Data(frame)
        var result = MeshResult(complete: nil, forward: [], excludeLink: fromLink, hops: nil)
        guard f.count > Self.header, f[0] == 0x46 else { return result }
        let hopsLeft = f[1]
        let id = f.subdata(in: 2..<18)
        let index = Int(f[18]) << 8 | Int(f[19])
        let count = Int(f[20]) << 8 | Int(f[21])
        guard count > 0, index < count else { return result }
        let k = key(id, index)
        guard seen[k] == nil else { return result }
        seen[k] = nowMs
        result.hops = Int(Self.initialHops) - Int(hopsLeft) + 1
        if hopsLeft > 1 {
            var forward = f
            forward[1] = hopsLeft - 1
            result.forward = [forward]
        }
        let payload = f.subdata(in: Self.header..<f.count)
        var assembly = assemblies[id] ?? Assembly(parts: [:], count: count, started: nowMs, bytes: 0)
        guard assembly.bytes + payload.count <= 1 << 20 else {
            assemblies[id] = nil
            return result
        }
        assembly.parts[index] = payload
        assembly.bytes += payload.count
        if assembly.parts.count == assembly.count {
            var envelope = Data(capacity: assembly.bytes)
            for i in 0..<assembly.count { envelope.append(assembly.parts[i] ?? Data()) }
            result.complete = envelope
            assemblies[id] = nil
        } else {
            if assemblies.count >= 128, assemblies[id] == nil,
                let oldest = assemblies.min(by: { $0.value.started < $1.value.started })?.key
            {
                assemblies[oldest] = nil
            }
            assemblies[id] = assembly
        }
        prune(nowMs)
        return result
    }

    private func key(_ id: Data, _ index: Int) -> Data {
        var k = id
        k.append(contentsOf: [UInt8(index >> 8), UInt8(index & 0xFF)])
        return k
    }

    private func prune(_ now: Int64) {
        if seen.count > 4096 {
            let cutoff = now - 600_000
            seen = seen.filter { $0.value > cutoff }
            if seen.count > 4096 {
                let sorted = seen.sorted { $0.value < $1.value }
                for (k, _) in sorted.prefix(seen.count - 4096) { seen[k] = nil }
            }
        }
        assemblies = assemblies.filter { now - $0.value.started < 30_000 }
    }
}
