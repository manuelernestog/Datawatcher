import Foundation
import Combine

/// Polls macOS `nettop` periodically, resolves processes to applications, records hourly
/// usage deltas into `UsageDatabase`, and publishes real-time throughput metrics.
@MainActor
public final class NetworkMonitor: ObservableObject {
    public let database: UsageDatabase
    public let resolver: AppResolver

    private static let pollIntervalKey = "datawatcher.pollInterval"
    private static let showSpeedMenuBarKey = "datawatcher.showSpeedInMenuBar"
    private static let includeSystemDefaultKey = "datawatcher.includeSystemByDefault"

    @Published public var isPaused: Bool = false {
        didSet {
            if isPaused != oldValue {
                if isPaused {
                    totalLiveInPerSec = 0
                    totalLiveOutPerSec = 0
                    liveSpeedsByApp = [:]
                } else {
                    let state = pollState
                    deltaQueue.async {
                        state.deltaTracker.reset()
                        state.lastSampleDate = nil
                    }
                    restartTimer()
                    triggerImmediatePoll()
                }
            }
        }
    }

    @Published public var pollIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(pollIntervalSeconds, forKey: Self.pollIntervalKey)
            restartTimer()
        }
    }

    @Published public var showSpeedInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showSpeedInMenuBar, forKey: Self.showSpeedMenuBarKey)
        }
    }

    @Published public var includeSystemByDefault: Bool {
        didSet {
            UserDefaults.standard.set(includeSystemByDefault, forKey: Self.includeSystemDefaultKey)
            refreshTodayStats()
        }
    }

    @Published public private(set) var liveSpeedsByApp: [String: (inPerSec: Double, outPerSec: Double)] = [:]
    @Published public private(set) var totalLiveInPerSec: Double = 0
    @Published public private(set) var totalLiveOutPerSec: Double = 0
    @Published public private(set) var liveHistory: [LiveSamplePoint] = []
    @Published public private(set) var todayTotalIn: Int64 = 0
    @Published public private(set) var todayTotalOut: Int64 = 0
    @Published public private(set) var topLiveApps: [AppUsageSummary] = []
    @Published public private(set) var lastUpdated: Date = Date()

    private final class PollState: @unchecked Sendable {
        var deltaTracker = DeltaTracker()
        var lastSampleDate: Date?
    }

    private let deltaQueue = DispatchQueue(label: "com.datawatcher.nettop", qos: .utility)
    private let pollState = PollState()
    private var pollTimer: Timer?
    private var isPolling: Bool = false

    public init(database: UsageDatabase, resolver: AppResolver = AppResolver()) {
        self.database = database
        self.resolver = resolver

        let savedInterval = UserDefaults.standard.double(forKey: Self.pollIntervalKey)
        self.pollIntervalSeconds = savedInterval > 0 ? savedInterval : 2.0

        if UserDefaults.standard.object(forKey: Self.showSpeedMenuBarKey) != nil {
            self.showSpeedInMenuBar = UserDefaults.standard.bool(forKey: Self.showSpeedMenuBarKey)
        } else {
            self.showSpeedInMenuBar = true
        }

        if UserDefaults.standard.object(forKey: Self.includeSystemDefaultKey) != nil {
            self.includeSystemByDefault = UserDefaults.standard.bool(forKey: Self.includeSystemDefaultKey)
        } else {
            self.includeSystemByDefault = true
        }

        refreshTodayStats()
    }

    public func start() {
        restartTimer()
        triggerImmediatePoll()
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    public func togglePause() {
        isPaused.toggle()
    }

    public func refreshTodayStats() {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let includeSys = includeSystemByDefault
        let db = database
        let speeds = liveSpeedsByApp

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let totals = db.fetchTotals(from: startOfDay, to: now, appId: nil, includeSystem: includeSys)
            let summaries = db.fetchAppSummaries(from: startOfDay, to: now, includeSystem: includeSys)
            let top5 = Array(summaries.prefix(5)).map { item -> AppUsageSummary in
                let live = speeds[item.app.id] ?? (0, 0)
                return AppUsageSummary(
                    app: item.app,
                    bytesIn: item.bytesIn,
                    bytesOut: item.bytesOut,
                    liveInPerSec: live.inPerSec,
                    liveOutPerSec: live.outPerSec
                )
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.todayTotalIn = totals.bytesIn
                self.todayTotalOut = totals.bytesOut
                self.topLiveApps = top5
            }
        }
    }

    private func restartTimer() {
        pollTimer?.invalidate()
        guard !isPaused else { return }
        let interval = max(1.0, pollIntervalSeconds)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerImmediatePoll()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    private func triggerImmediatePoll() {
        guard !isPaused, !isPolling else { return }
        isPolling = true
        let includeSys = includeSystemByDefault
        let fallbackInterval = pollIntervalSeconds
        let state = pollState
        let db = database
        let appResolver = resolver

        deltaQueue.async { [weak self] in
            let output = Self.runNettopSnapshot()
            let now = Date()
            let samples = NettopParser.parse(output)
            let deltas = state.deltaTracker.ingest(samples)

            let elapsed: Double
            if let prevDate = state.lastSampleDate {
                elapsed = max(0.2, now.timeIntervalSince(prevDate))
            } else {
                elapsed = fallbackInterval
            }
            let hadPrevious = state.lastSampleDate != nil
            state.lastSampleDate = now

            // Group deltas by canonical app record
            var groupedDeltas: [String: (app: AppRecord, inBytes: Int64, outBytes: Int64)] = [:]
            for delta in deltas {
                let app = appResolver.resolve(pid: delta.pid, fallbackName: delta.processName)
                if let existing = groupedDeltas[app.id] {
                    groupedDeltas[app.id] = (
                        existing.app,
                        existing.inBytes + delta.deltaIn,
                        existing.outBytes + delta.deltaOut
                    )
                } else {
                    groupedDeltas[app.id] = (app, delta.deltaIn, delta.deltaOut)
                }
            }

            let batch = groupedDeltas.values.map { ($0.app, $0.inBytes, $0.outBytes) }
            if !batch.isEmpty {
                db.recordBatch(batch, at: now)
            }

            var perAppSpeeds: [String: (inPerSec: Double, outPerSec: Double)] = [:]
            var totalInSec: Double = 0
            var totalOutSec: Double = 0

            if hadPrevious {
                for (appId, entry) in groupedDeltas {
                    let inRate = Double(entry.inBytes) / elapsed
                    let outRate = Double(entry.outBytes) / elapsed
                    perAppSpeeds[appId] = (inRate, outRate)
                    if includeSys || !entry.app.isSystem {
                        totalInSec += inRate
                        totalOutSec += outRate
                    }
                }
            }

            let startOfDay = Calendar.current.startOfDay(for: now)
            let totals = db.fetchTotals(from: startOfDay, to: now, appId: nil, includeSystem: includeSys)
            let summaries = db.fetchAppSummaries(from: startOfDay, to: now, includeSystem: includeSys)
            let top5 = Array(summaries.prefix(5)).map { item -> AppUsageSummary in
                let live = perAppSpeeds[item.app.id] ?? (0, 0)
                return AppUsageSummary(
                    app: item.app,
                    bytesIn: item.bytesIn,
                    bytesOut: item.bytesOut,
                    liveInPerSec: live.inPerSec,
                    liveOutPerSec: live.outPerSec
                )
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                self.liveSpeedsByApp = perAppSpeeds
                self.totalLiveInPerSec = totalInSec
                self.totalLiveOutPerSec = totalOutSec
                self.todayTotalIn = totals.bytesIn
                self.todayTotalOut = totals.bytesOut
                self.topLiveApps = top5
                self.lastUpdated = now

                if hadPrevious {
                    self.liveHistory.append(LiveSamplePoint(
                        timestamp: now,
                        bytesInPerSec: totalInSec,
                        bytesOutPerSec: totalOutSec
                    ))
                    if self.liveHistory.count > 60 {
                        self.liveHistory.removeFirst(self.liveHistory.count - 60)
                    }
                }
            }
        }
    }

    /// Executes `/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out -t wifi -t wired` synchronously.
    public nonisolated static func runNettopSnapshot() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", "-t", "wifi", "-t", "wired"]
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
