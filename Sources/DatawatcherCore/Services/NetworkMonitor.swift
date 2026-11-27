import Foundation
import Combine
import AppKit

/// Streams kernel-level per-process delta frames from a single persistent `nettop -P -d` process,
/// samples active physical interface counters via `InterfaceBandwidthReader` (`sysctl`), resolves
/// applications while excluding duplicate L3 VPN tunnel daemons, and persists hourly deltas to SQLite.
@MainActor
public final class NetworkMonitor: ObservableObject {
    public let database: UsageDatabase
    public let resolver: AppResolver

    private static let pollIntervalKey = "datawatcher.pollInterval"
    private static let showSpeedMenuBarKey = "datawatcher.showSpeedInMenuBar"
    private static let hideMenuBarIconKey = "datawatcher.hideMenuBarIcon"
    private static let includeSystemDefaultKey = "datawatcher.includeSystemByDefault"

    @Published public var isPaused: Bool = false {
        didSet {
            if isPaused != oldValue {
                let state = pollState
                if isPaused {
                    totalLiveInPerSec = 0
                    totalLiveOutPerSec = 0
                    liveSpeedsByApp = [:]
                    deltaQueue.async {
                        Self.stopStreamLocked(state: state)
                    }
                } else {
                    let db = database
                    let appResolver = resolver
                    deltaQueue.async { [weak self] in
                        state.shouldRun = true
                        Self.startStreamLocked(state: state, queue: self?.deltaQueue, db: db, appResolver: appResolver, monitor: self)
                    }
                }
            }
        }
    }

    @Published public var pollIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(pollIntervalSeconds, forKey: Self.pollIntervalKey)
            let newInterval = pollIntervalSeconds
            let state = pollState
            let db = database
            let appResolver = resolver
            deltaQueue.async { [weak self] in
                state.intervalSeconds = newInterval
                if state.shouldRun {
                    Self.startStreamLocked(state: state, queue: self?.deltaQueue, db: db, appResolver: appResolver, monitor: self)
                }
            }
        }
    }

    @Published public var showSpeedInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showSpeedInMenuBar, forKey: Self.showSpeedMenuBarKey)
            if !showSpeedInMenuBar && hideMenuBarIcon {
                hideMenuBarIcon = false
            }
        }
    }

    @Published public var hideMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideMenuBarIcon, forKey: Self.hideMenuBarIconKey)
        }
    }

    @Published public var includeSystemByDefault: Bool {
        didSet {
            UserDefaults.standard.set(includeSystemByDefault, forKey: Self.includeSystemDefaultKey)
            let includeSys = includeSystemByDefault
            let state = pollState
            deltaQueue.async {
                state.includeSystem = includeSys
                state.hasLoadedTodayStats = false
            }
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
    @Published public private(set) var databaseRevision: UInt64 = 0

    private final class PollState: @unchecked Sendable {
        var streamProcess: Process?
        var streamInPipe: Pipe?
        var streamOutHandle: FileHandle?
        var streamGeneration: UInt64 = 0
        var shouldRun: Bool = false
        var isPopoverVisible: Bool = false
        var databaseRevision: UInt64 = 0
        var assembler = NettopStreamAssembler()
        var interfaceReader = InterfaceBandwidthReader()
        var lastFrameDate: Date?
        var pendingFlushWorkItem: DispatchWorkItem?
        var restartWorkItem: DispatchWorkItem?
        var hasLoadedTodayStats: Bool = false
        var lastStatsDayStart: Date?
        var cachedTopSummaries: [AppUsageSummary] = []
        var cachedTodayTotals: (bytesIn: Int64, bytesOut: Int64) = (0, 0)
        var includeSystem: Bool = true
        var intervalSeconds: Double = 2.0
    }

    private let deltaQueue = DispatchQueue(label: "com.datawatcher.nettop", qos: .utility)
    private let pollState = PollState()
    private var wakeObserver: NSObjectProtocol?

    public init(database: UsageDatabase, resolver: AppResolver = AppResolver()) {
        self.database = database
        self.resolver = resolver

        let savedInterval = UserDefaults.standard.double(forKey: Self.pollIntervalKey)
        let resolvedInterval = savedInterval > 0 ? savedInterval : 2.0
        self.pollIntervalSeconds = resolvedInterval

        let initialShowSpeed: Bool
        if UserDefaults.standard.object(forKey: Self.showSpeedMenuBarKey) != nil {
            initialShowSpeed = UserDefaults.standard.bool(forKey: Self.showSpeedMenuBarKey)
        } else {
            initialShowSpeed = true
        }
        self.showSpeedInMenuBar = initialShowSpeed

        if UserDefaults.standard.object(forKey: Self.hideMenuBarIconKey) != nil {
            self.hideMenuBarIcon = initialShowSpeed && UserDefaults.standard.bool(forKey: Self.hideMenuBarIconKey)
        } else {
            self.hideMenuBarIcon = false
        }

        let initialIncludeSys: Bool
        if UserDefaults.standard.object(forKey: Self.includeSystemDefaultKey) != nil {
            initialIncludeSys = UserDefaults.standard.bool(forKey: Self.includeSystemDefaultKey)
        } else {
            initialIncludeSys = true
        }
        self.includeSystemByDefault = initialIncludeSys

        self.pollState.intervalSeconds = resolvedInterval
        self.pollState.includeSystem = initialIncludeSys

        refreshTodayStats()
    }

    deinit {
        pollState.streamOutHandle?.readabilityHandler = nil
        if let proc = pollState.streamProcess, proc.isRunning {
            proc.terminate()
        }
        try? pollState.streamInPipe?.fileHandleForWriting.close()
    }

    public func start() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemWake()
                }
            }
        }

        guard !isPaused else { return }
        let state = pollState
        let db = database
        let appResolver = resolver
        deltaQueue.async { [weak self] in
            state.shouldRun = true
            Self.startStreamLocked(state: state, queue: self?.deltaQueue, db: db, appResolver: appResolver, monitor: self)
        }
    }

    public func stop() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        let state = pollState
        deltaQueue.sync {
            Self.stopStreamLocked(state: state)
        }
    }

    public func togglePause() {
        isPaused.toggle()
    }

    private func handleSystemWake() {
        guard !isPaused else { return }
        let state = pollState
        let db = database
        let appResolver = resolver
        deltaQueue.async { [weak self] in
            guard state.shouldRun else { return }
            Self.startStreamLocked(state: state, queue: self?.deltaQueue, db: db, appResolver: appResolver, monitor: self)
        }
    }

    public func setPopoverVisible(_ visible: Bool) {
        let state = pollState
        deltaQueue.async {
            state.isPopoverVisible = visible
        }
        if visible {
            refreshTodayStats()
        }
    }

    public func refreshTodayStats() {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let includeSys = includeSystemByDefault
        let db = database
        let state = pollState
        let speeds = liveSpeedsByApp

        deltaQueue.async { [weak self] in
            let totals = db.fetchTotals(from: startOfDay, to: now, appId: nil, includeSystem: includeSys)
            let summaries = db.fetchAppSummaries(from: startOfDay, to: now, includeSystem: includeSys)
            state.cachedTodayTotals = totals
            state.cachedTopSummaries = summaries
            state.lastStatsDayStart = startOfDay
            state.hasLoadedTodayStats = true

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
                if self.todayTotalIn != totals.bytesIn {
                    self.todayTotalIn = totals.bytesIn
                }
                if self.todayTotalOut != totals.bytesOut {
                    self.todayTotalOut = totals.bytesOut
                }
                if self.topLiveApps != top5 {
                    self.topLiveApps = top5
                }
            }
        }
    }

    // MARK: - Persistent Streaming Engine (deltaQueue only)

    private nonisolated static func stopStreamLocked(state: PollState) {
        state.shouldRun = false
        terminateExistingProcessLocked(state: state)
    }

    private nonisolated static func terminateExistingProcessLocked(state: PollState) {
        state.streamGeneration &+= 1
        state.pendingFlushWorkItem?.cancel()
        state.pendingFlushWorkItem = nil
        state.restartWorkItem?.cancel()
        state.restartWorkItem = nil

        state.streamOutHandle?.readabilityHandler = nil
        state.streamOutHandle = nil

        if let proc = state.streamProcess {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            state.streamProcess = nil
        }

        if let inPipe = state.streamInPipe {
            try? inPipe.fileHandleForWriting.close()
            state.streamInPipe = nil
        }

        state.assembler.reset()
        state.interfaceReader.reset()
        state.lastFrameDate = nil
    }

    private nonisolated static func startStreamLocked(
        state: PollState,
        queue: DispatchQueue?,
        db: UsageDatabase,
        appResolver: AppResolver,
        monitor: NetworkMonitor?
    ) {
        guard let queue else { return }
        terminateExistingProcessLocked(state: state)
        guard state.shouldRun else { return }

        let generation = state.streamGeneration
        let sampleInterval = max(1, Int(state.intervalSeconds.rounded()))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-P", "-d", "-L", "0",
            "-s", "\(sampleInterval)",
            "-x", "-n",
            "-J", "bytes_in,bytes_out",
            "-t", "wifi", "-t", "wired"
        ]

        var env = ProcessInfo.processInfo.environment
        env["NSUnbufferedIO"] = "YES"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env

        // Keep stdin attached to an open Pipe rather than /dev/null; nettop's stdin
        // event loop spins at ~135% CPU on immediate EOF from /dev/null.
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardError = FileHandle.nullDevice

        let outPipe = Pipe()
        process.standardOutput = outPipe
        let outHandle = outPipe.fileHandleForReading

        state.streamProcess = process
        state.streamInPipe = inPipe
        state.streamOutHandle = outHandle

        // Establish initial physical-interface baseline before the first delta frame arrives.
        _ = state.interfaceReader.sample(at: Date())

        outHandle.readabilityHandler = { [weak monitor] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }

            let chunk = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            queue.async {
                guard generation == state.streamGeneration, state.shouldRun else { return }

                let completedFrames = state.assembler.append(chunk)
                if !completedFrames.isEmpty {
                    state.pendingFlushWorkItem?.cancel()
                    state.pendingFlushWorkItem = nil
                    for frame in completedFrames {
                        processDeltaFrameLocked(
                            frame,
                            generation: generation,
                            state: state,
                            db: db,
                            appResolver: appResolver,
                            monitor: monitor
                        )
                    }
                }

                // A frame's lines arrive in a quick burst; flush shortly after the burst settles
                // so live speeds update immediately without waiting for the next interval's header.
                state.pendingFlushWorkItem?.cancel()
                let flushItem = DispatchWorkItem {
                    guard generation == state.streamGeneration, state.shouldRun else { return }
                    if let flushed = state.assembler.flushCurrentFrame() {
                        processDeltaFrameLocked(
                            flushed,
                            generation: generation,
                            state: state,
                            db: db,
                            appResolver: appResolver,
                            monitor: monitor
                        )
                    }
                }
                state.pendingFlushWorkItem = flushItem
                queue.asyncAfter(deadline: .now() + 0.06, execute: flushItem)
            }
        }

        process.terminationHandler = { [weak monitor] _ in
            queue.async {
                guard generation == state.streamGeneration, state.shouldRun else { return }
                state.streamOutHandle?.readabilityHandler = nil
                state.streamOutHandle = nil
                if let inPipe = state.streamInPipe {
                    try? inPipe.fileHandleForWriting.close()
                    state.streamInPipe = nil
                }
                state.streamProcess = nil

                state.restartWorkItem?.cancel()
                let restartItem = DispatchWorkItem {
                    guard generation == state.streamGeneration, state.shouldRun else { return }
                    startStreamLocked(state: state, queue: queue, db: db, appResolver: appResolver, monitor: monitor)
                }
                state.restartWorkItem = restartItem
                queue.asyncAfter(deadline: .now() + 2.0, execute: restartItem)
            }
        }

        do {
            try process.run()
        } catch {
            outHandle.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            state.streamOutHandle = nil
            state.streamInPipe = nil
            state.streamProcess = nil
        }
    }

    private nonisolated static func processDeltaFrameLocked(
        _ deltas: [ProcessDelta],
        generation: UInt64,
        state: PollState,
        db: UsageDatabase,
        appResolver: AppResolver,
        monitor: NetworkMonitor?
    ) {
        guard generation == state.streamGeneration, state.shouldRun else { return }

        let now = Date()
        let elapsed: Double
        if let prevDate = state.lastFrameDate {
            elapsed = max(0.5, now.timeIntervalSince(prevDate))
        } else {
            elapsed = max(1.0, state.intervalSeconds)
        }
        state.lastFrameDate = now

        let ifaceSample = state.interfaceReader.sample(at: now)
        let maxReasonableDelta = Int64(max(1.0, 1_250_000_000.0 * elapsed))

        var groupedDeltas: [String: (app: AppRecord, inBytes: Int64, outBytes: Int64)] = [:]
        for delta in deltas {
            let resolved = appResolver.resolveWithMetadata(pid: delta.pid, fallbackName: delta.processName)
            if resolved.isVPNTunnel {
                continue
            }

            let dIn = (delta.deltaIn >= 0 && delta.deltaIn <= maxReasonableDelta) ? delta.deltaIn : 0
            let dOut = (delta.deltaOut >= 0 && delta.deltaOut <= maxReasonableDelta) ? delta.deltaOut : 0
            guard dIn > 0 || dOut > 0 else { continue }

            let app = resolved.record
            if let existing = groupedDeltas[app.id] {
                groupedDeltas[app.id] = (
                    existing.app,
                    existing.inBytes + dIn,
                    existing.outBytes + dOut
                )
            } else {
                groupedDeltas[app.id] = (app, dIn, dOut)
            }
        }

        let includeSys = state.includeSystem
        let batch = groupedDeltas.values.map { ($0.app, $0.inBytes, $0.outBytes) }
        let shouldUpdatePopoverStats = state.isPopoverVisible

        if !batch.isEmpty {
            db.recordBatch(batch, at: now)
            state.databaseRevision &+= 1
        }

        if shouldUpdatePopoverStats {
            let startOfDay = Calendar.current.startOfDay(for: now)
            if !batch.isEmpty || !state.hasLoadedTodayStats || state.lastStatsDayStart != startOfDay {
                state.cachedTodayTotals = db.fetchTotals(from: startOfDay, to: now, appId: nil, includeSystem: includeSys)
                state.cachedTopSummaries = db.fetchAppSummaries(from: startOfDay, to: now, includeSystem: includeSys)
                state.lastStatsDayStart = startOfDay
                state.hasLoadedTodayStats = true
            }
        }

        var perAppSpeeds: [String: (inPerSec: Double, outPerSec: Double)] = [:]
        var fallbackTotalInSec: Double = 0
        var fallbackTotalOutSec: Double = 0

        for (appId, entry) in groupedDeltas {
            let inRate = Double(entry.inBytes) / elapsed
            let outRate = Double(entry.outBytes) / elapsed
            perAppSpeeds[appId] = (inRate, outRate)
            if includeSys || !entry.app.isSystem {
                fallbackTotalInSec += inRate
                fallbackTotalOutSec += outRate
            }
        }

        let totalInSec: Double
        let totalOutSec: Double
        if let ifaceSample {
            totalInSec = ifaceSample.bytesInPerSec
            totalOutSec = ifaceSample.bytesOutPerSec
        } else {
            totalInSec = fallbackTotalInSec
            totalOutSec = fallbackTotalOutSec
        }

        let totals = state.cachedTodayTotals
        let top5: [AppUsageSummary]
        if shouldUpdatePopoverStats {
            top5 = Array(state.cachedTopSummaries.prefix(5)).map { item -> AppUsageSummary in
                let live = perAppSpeeds[item.app.id] ?? (0, 0)
                return AppUsageSummary(
                    app: item.app,
                    bytesIn: item.bytesIn,
                    bytesOut: item.bytesOut,
                    liveInPerSec: live.inPerSec,
                    liveOutPerSec: live.outPerSec
                )
            }
        } else {
            top5 = []
        }

        let dbRevision = state.databaseRevision

        Task { @MainActor [weak monitor] in
            guard let monitor, !monitor.isPaused else { return }
            if !Self.speedsEqual(monitor.liveSpeedsByApp, perAppSpeeds) {
                monitor.liveSpeedsByApp = perAppSpeeds
            }
            if monitor.totalLiveInPerSec != totalInSec {
                monitor.totalLiveInPerSec = totalInSec
            }
            if monitor.totalLiveOutPerSec != totalOutSec {
                monitor.totalLiveOutPerSec = totalOutSec
            }
            if shouldUpdatePopoverStats {
                if monitor.todayTotalIn != totals.bytesIn {
                    monitor.todayTotalIn = totals.bytesIn
                }
                if monitor.todayTotalOut != totals.bytesOut {
                    monitor.todayTotalOut = totals.bytesOut
                }
                if monitor.topLiveApps != top5 {
                    monitor.topLiveApps = top5
                }
            }
            if monitor.databaseRevision != dbRevision {
                monitor.databaseRevision = dbRevision
            }
            monitor.lastUpdated = now

            monitor.liveHistory.append(LiveSamplePoint(
                timestamp: now,
                bytesInPerSec: totalInSec,
                bytesOutPerSec: totalOutSec
            ))
            if monitor.liveHistory.count > 60 {
                monitor.liveHistory.removeFirst(monitor.liveHistory.count - 60)
            }
        }
    }

    private nonisolated static func speedsEqual(
        _ lhs: [String: (inPerSec: Double, outPerSec: Double)],
        _ rhs: [String: (inPerSec: Double, outPerSec: Double)]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, lVal) in lhs {
            guard let rVal = rhs[key],
                  lVal.inPerSec == rVal.inPerSec,
                  lVal.outPerSec == rVal.outPerSec else {
                return false
            }
        }
        return true
    }

    /// Executes `/usr/bin/nettop -P -L 1 -x -n -J bytes_in,bytes_out -t wifi -t wired` synchronously.
    public nonisolated static func runNettopSnapshot() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out", "-t", "wifi", "-t", "wired"]
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

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
