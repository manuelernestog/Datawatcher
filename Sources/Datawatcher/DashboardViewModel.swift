import Foundation
import Combine
import DatawatcherCore

@MainActor
final class DashboardViewModel: ObservableObject {
    let monitor: NetworkMonitor

    @Published var selectedPreset: DateRangePreset = .today {
        didSet { reloadData() }
    }
    @Published var customStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var customEndDate: Date = Date()
    @Published var selectedAppId: String? = nil {
        didSet { reloadData() }
    }
    @Published var selectedAppName: String? = nil
    @Published var searchQuery: String = ""
    @Published var includeSystem: Bool {
        didSet { reloadData() }
    }
    @Published var sortOrder: AppSortOrder = .totalDesc

    @Published private(set) var rawSummaries: [AppUsageSummary] = []
    @Published private(set) var timeSeries: [TimeBucketPoint] = []
    @Published private(set) var periodBytesIn: Int64 = 0
    @Published private(set) var periodBytesOut: Int64 = 0

    private var cancellables = Set<AnyCancellable>()
    private var lastReloadDate: Date = .distantPast

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        self.includeSystem = monitor.includeSystemByDefault

        monitor.$lastUpdated
            .sink { [weak self] now in
                guard let self else { return }
                if now.timeIntervalSince(self.lastReloadDate) >= 2.0 {
                    self.reloadData()
                }
            }
            .store(in: &cancellables)

        reloadData()
    }

    var currentBounds: (from: Date?, to: Date?) {
        selectedPreset.dateBounds(
            now: Date(),
            customStart: customStartDate,
            customEnd: customEndDate
        )
    }

    var currentGranularity: ChartGranularity {
        selectedPreset.defaultGranularity(
            customStart: customStartDate,
            customEnd: customEndDate
        )
    }

    func applyCustomRange(start: Date, end: Date) {
        customStartDate = min(start, end)
        customEndDate = max(start, end)
        selectedPreset = .custom
        reloadData()
    }

    func toggleAppFilter(_ app: AppRecord) {
        if selectedAppId == app.id {
            selectedAppId = nil
            selectedAppName = nil
        } else {
            selectedAppId = app.id
            selectedAppName = app.name
        }
    }

    func clearAppFilter() {
        selectedAppId = nil
        selectedAppName = nil
    }

    /// App summaries merged with live speeds, filtered by search query, and sorted.
    var displayedApps: [AppUsageSummary] {
        let speeds = monitor.liveSpeedsByApp
        let merged = rawSummaries.map { item -> AppUsageSummary in
            let live = speeds[item.app.id] ?? (0, 0)
            return AppUsageSummary(
                app: item.app,
                bytesIn: item.bytesIn,
                bytesOut: item.bytesOut,
                liveInPerSec: live.inPerSec,
                liveOutPerSec: live.outPerSec
            )
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? merged : merged.filter {
            $0.app.name.lowercased().contains(query) ||
            ($0.app.bundleId?.lowercased().contains(query) ?? false)
        }

        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .totalDesc:
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
            case .downloadDesc:
                if lhs.bytesIn != rhs.bytesIn { return lhs.bytesIn > rhs.bytesIn }
                return lhs.totalBytes > rhs.totalBytes
            case .uploadDesc:
                if lhs.bytesOut != rhs.bytesOut { return lhs.bytesOut > rhs.bytesOut }
                return lhs.totalBytes > rhs.totalBytes
            case .liveDesc:
                if lhs.totalLivePerSec != rhs.totalLivePerSec { return lhs.totalLivePerSec > rhs.totalLivePerSec }
                return lhs.totalBytes > rhs.totalBytes
            case .nameAsc:
                return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
            }
        }
    }

    var filteredLiveInPerSec: Double {
        if let selectedAppId {
            return monitor.liveSpeedsByApp[selectedAppId]?.inPerSec ?? 0
        }
        return monitor.totalLiveInPerSec
    }

    var filteredLiveOutPerSec: Double {
        if let selectedAppId {
            return monitor.liveSpeedsByApp[selectedAppId]?.outPerSec ?? 0
        }
        return monitor.totalLiveOutPerSec
    }

    func reloadData() {
        lastReloadDate = Date()
        let bounds = currentBounds
        let granularity = currentGranularity
        let appId = selectedAppId
        let includeSys = includeSystem
        let db = monitor.database

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summaries = db.fetchAppSummaries(
                from: bounds.from,
                to: bounds.to,
                includeSystem: includeSys
            )
            let series = db.fetchTimeSeries(
                from: bounds.from,
                to: bounds.to,
                appId: appId,
                granularity: granularity,
                includeSystem: includeSys
            )
            let totals = db.fetchTotals(
                from: bounds.from,
                to: bounds.to,
                appId: appId,
                includeSystem: includeSys
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rawSummaries = summaries
                self.timeSeries = series
                self.periodBytesIn = totals.bytesIn
                self.periodBytesOut = totals.bytesOut
            }
        }
    }

    func generateCSVExport() -> String {
        let bounds = currentBounds
        return monitor.database.exportCSV(
            from: bounds.from,
            to: bounds.to,
            appId: selectedAppId,
            includeSystem: includeSystem
        )
    }
}

