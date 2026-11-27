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

/// Parses CSV-like output from `nettop -P -L ... -x -J bytes_in,bytes_out -t wifi -t wired`.
public enum NettopParser {
    /// Returns `true` if `line` is a `nettop` frame header (e.g. `,bytes_in,bytes_out,`).
    public static func isHeaderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(",bytes_in,bytes_out") {
            return true
        }
        let columns = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 3 else { return false }
        return columns[0].trimmingCharacters(in: .whitespaces).isEmpty &&
            columns[1].trimmingCharacters(in: .whitespaces) == "bytes_in"
    }

    private static func parseNonNegativeByteCount(_ token: String) -> UInt64? {
        if let signed = Int64(token) {
            return signed >= 0 ? UInt64(signed) : 0
        }
        return UInt64(token)
    }

    private static func parseRow(_ rawLine: String) -> (processName: String, pid: Int32, bytesIn: UInt64, bytesOut: UInt64)? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || isHeaderLine(line) { return nil }

        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 3 else { return nil }

        let procPidToken = columns[0].trimmingCharacters(in: .whitespaces)
        if procPidToken.isEmpty || procPidToken == "bytes_in" { return nil }

        guard let lastDot = procPidToken.lastIndex(of: ".") else { return nil }
        let namePart = String(procPidToken[..<lastDot]).trimmingCharacters(in: .whitespaces)
        let pidPart = String(procPidToken[procPidToken.index(after: lastDot)...])
        guard !namePart.isEmpty, let pid = Int32(pidPart) else { return nil }

        let inToken = columns[1].trimmingCharacters(in: .whitespaces)
        let outToken = columns[2].trimmingCharacters(in: .whitespaces)
        guard let bytesIn = parseNonNegativeByteCount(inToken),
              let bytesOut = parseNonNegativeByteCount(outToken) else {
            return nil
        }

        return (namePart, pid, bytesIn, bytesOut)
    }

    public static func parse(_ output: String) -> [RawProcessSample] {
        var results: [RawProcessSample] = []
        let lines = output.split(whereSeparator: \.isNewline)

        for rawLine in lines {
            guard let row = parseRow(String(rawLine)) else { continue }
            results.append(RawProcessSample(
                processName: row.processName,
                pid: row.pid,
                bytesIn: row.bytesIn,
                bytesOut: row.bytesOut
            ))
        }

        return results
    }

    /// Parses lines from a single `nettop -d` delta frame, clamping negative kernel reset
    /// artifacts to `0` and omitting rows with zero activity.
    public static func parseDeltaFrame(_ lines: [String]) -> [ProcessDelta] {
        var deltas: [ProcessDelta] = []
        for rawLine in lines {
            guard let row = parseRow(rawLine) else { continue }
            guard row.bytesIn > 0 || row.bytesOut > 0 else { continue }
            deltas.append(ProcessDelta(
                processName: row.processName,
                pid: row.pid,
                deltaIn: Int64(clamping: row.bytesIn),
                deltaOut: Int64(clamping: row.bytesOut)
            ))
        }
        return deltas
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
    /// traffic is not attributed to the current session. When a PID's counter decreases
    /// (because `nettop` sums currently open sockets and one closed) or a PID appears for the
    /// first time, its baseline is recorded without fabricating a spike.
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

            guard let prev = previous[sample.pid] else {
                continue
            }

            let dIn = sample.bytesIn >= prev.bytesIn ? (sample.bytesIn - prev.bytesIn) : 0
            let dOut = sample.bytesOut >= prev.bytesOut ? (sample.bytesOut - prev.bytesOut) : 0

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

/// Incrementally assembles `nettop -P -d -L 0` streaming stdout chunks into per-interval delta frames.
/// Frame 1 (the initial cumulative baseline emitted by `nettop`) is discarded automatically; frames 2+
/// are emitted as `[ProcessDelta]`.
public struct NettopStreamAssembler: Sendable {
    private var partialLineBuffer: String = ""
    private var currentFrameLines: [String] = []
    private var frameIndex: Int = 0
    private var hasFlushedCurrentFrame: Bool = false

    public init() {}

    /// Resets stream buffering state (e.g., when restarting `nettop`).
    public mutating func reset() {
        partialLineBuffer.removeAll(keepingCapacity: true)
        currentFrameLines.removeAll(keepingCapacity: true)
        frameIndex = 0
        hasFlushedCurrentFrame = false
    }

    /// Appends a UTF-8 stdout chunk and returns any complete delta frames finished by incoming headers.
    public mutating func append(_ chunk: String) -> [[ProcessDelta]] {
        partialLineBuffer.append(chunk)
        var emittedFrames: [[ProcessDelta]] = []

        let utf8 = partialLineBuffer.utf8
        var searchStart = utf8.startIndex
        while let newlineIndex = utf8[searchStart...].firstIndex(of: 0x0A) {
            var lineEnd = newlineIndex
            if lineEnd > searchStart {
                let prev = utf8.index(before: lineEnd)
                if utf8[prev] == 0x0D {
                    lineEnd = prev
                }
            }
            let line = String(decoding: utf8[searchStart..<lineEnd], as: UTF8.self)
            searchStart = utf8.index(after: newlineIndex)

            if NettopParser.isHeaderLine(line) {
                if frameIndex >= 2 && !hasFlushedCurrentFrame {
                    emittedFrames.append(NettopParser.parseDeltaFrame(currentFrameLines))
                }
                frameIndex += 1
                currentFrameLines.removeAll(keepingCapacity: true)
                hasFlushedCurrentFrame = false
            } else if frameIndex >= 2 {
                currentFrameLines.append(line)
            }
        }

        if searchStart > utf8.startIndex {
            partialLineBuffer.removeSubrange(..<searchStart)
        }

        return emittedFrames
    }

    /// Flushes the currently accumulated delta frame (for frame 2+) once its burst of lines settles.
    /// Returns `nil` if the baseline frame has not finished or the current frame was already flushed.
    public mutating func flushCurrentFrame() -> [ProcessDelta]? {
        guard frameIndex >= 2 && !hasFlushedCurrentFrame else {
            return nil
        }
        hasFlushedCurrentFrame = true
        let deltas = NettopParser.parseDeltaFrame(currentFrameLines)
        currentFrameLines.removeAll(keepingCapacity: true)
        return deltas
    }
}

