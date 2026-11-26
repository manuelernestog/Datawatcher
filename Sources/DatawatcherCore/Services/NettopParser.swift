import Foundation

/// A single raw snapshot row parsed from `nettop -P -L 1 -x -J bytes_in,bytes_out`.
public struct RawProcessSample: Equatable, Sendable {
    public let processName: String
    public let pid: Int32
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(processName: String, pid: Int32, bytesIn: UInt64, bytesOut: UInt64) {
        self.processName = processName
        self.pid = pid
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Incremental byte delta computed between consecutive `nettop` snapshots.
public struct ProcessDelta: Equatable, Sendable {
    public let processName: String
    public let pid: Int32
    public let deltaIn: Int64
    public let deltaOut: Int64

    public init(processName: String, pid: Int32, deltaIn: Int64, deltaOut: Int64) {
        self.processName = processName
        self.pid = pid
        self.deltaIn = deltaIn
        self.deltaOut = deltaOut
    }
}

/// Parses CSV-like output from `nettop -P -L 1 -x -J bytes_in,bytes_out -t wifi -t wired`.
public enum NettopParser {
    public static func parse(_ output: String) -> [RawProcessSample] {
        var results: [RawProcessSample] = []
        let lines = output.split(whereSeparator: \.isNewline)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }

            let procPidToken = columns[0].trimmingCharacters(in: .whitespaces)
            if procPidToken.isEmpty || procPidToken == "bytes_in" { continue }

            guard let lastDot = procPidToken.lastIndex(of: ".") else { continue }
            let namePart = String(procPidToken[..<lastDot]).trimmingCharacters(in: .whitespaces)
            let pidPart = String(procPidToken[procPidToken.index(after: lastDot)...])
            guard !namePart.isEmpty, let pid = Int32(pidPart) else { continue }

            let inToken = columns[1].trimmingCharacters(in: .whitespaces)
            let outToken = columns[2].trimmingCharacters(in: .whitespaces)
            guard let bytesIn = UInt64(inToken), let bytesOut = UInt64(outToken) else { continue }

            results.append(RawProcessSample(
                processName: namePart,
                pid: pid,
                bytesIn: bytesIn,
                bytesOut: bytesOut
            ))
        }

        return results
    }
}

/// Tracks cumulative per-PID byte counters across polls to compute non-negative deltas.
public struct DeltaTracker: Sendable {
    private struct CounterPair: Sendable {
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private var previous: [Int32: CounterPair] = [:]
    private(set) public var hasBaseline: Bool = false

    public init() {}

    /// Resets the baseline (e.g., when monitoring resumes after being paused).
    public mutating func reset() {
        previous.removeAll()
        hasBaseline = false
    }

    /// Consumes a snapshot of cumulative counters and returns incremental byte deltas.
    /// The very first call establishes the baseline without emitting deltas so boot-time
    /// traffic is not attributed to the current session.
    public mutating func ingest(_ samples: [RawProcessSample]) -> [ProcessDelta] {
        var nextMap: [Int32: CounterPair] = [:]
        nextMap.reserveCapacity(samples.count)

        if !hasBaseline {
            for sample in samples {
                nextMap[sample.pid] = CounterPair(bytesIn: sample.bytesIn, bytesOut: sample.bytesOut)
            }
            previous = nextMap
            hasBaseline = true
            return []
        }

        var deltas: [ProcessDelta] = []
        for sample in samples {
            nextMap[sample.pid] = CounterPair(bytesIn: sample.bytesIn, bytesOut: sample.bytesOut)

            let dIn: UInt64
            let dOut: UInt64

            if let prev = previous[sample.pid] {
                dIn = sample.bytesIn >= prev.bytesIn ? (sample.bytesIn - prev.bytesIn) : sample.bytesIn
                dOut = sample.bytesOut >= prev.bytesOut ? (sample.bytesOut - prev.bytesOut) : sample.bytesOut
            } else {
                dIn = sample.bytesIn
                dOut = sample.bytesOut
            }

            if dIn > 0 || dOut > 0 {
                deltas.append(ProcessDelta(
                    processName: sample.processName,
                    pid: sample.pid,
                    deltaIn: Int64(clamping: dIn),
                    deltaOut: Int64(clamping: dOut)
                ))
            }
        }

        previous = nextMap
        return deltas
    }
}

