import Foundation

/// Represents a resolved macOS application or system process tracked by Datawatcher.
public struct AppRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let bundleId: String?
    public let appPath: String?
    public let isSystem: Bool

    public init(
        id: String,
        name: String,
        bundleId: String? = nil,
        appPath: String? = nil,
        isSystem: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.appPath = appPath
        self.isSystem = isSystem
    }
}

/// Aggregated network usage and optional live transfer speed for an app.
public struct AppUsageSummary: Identifiable, Hashable, Sendable {
    public var id: String { app.id }
    public let app: AppRecord
    public let bytesIn: Int64
    public let bytesOut: Int64
    public let liveInPerSec: Double
    public let liveOutPerSec: Double

    public var totalBytes: Int64 { bytesIn + bytesOut }
    public var totalLivePerSec: Double { liveInPerSec + liveOutPerSec }

    public init(
        app: AppRecord,
        bytesIn: Int64,
        bytesOut: Int64,
        liveInPerSec: Double = 0,
        liveOutPerSec: Double = 0
    ) {
        self.app = app
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.liveInPerSec = liveInPerSec
        self.liveOutPerSec = liveOutPerSec
    }
}

/// Aggregated historical traffic for a specific time bucket.
public struct TimeBucketPoint: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let bytesIn: Int64
    public let bytesOut: Int64

    public var totalBytes: Int64 { bytesIn + bytesOut }

    public init(date: Date, bytesIn: Int64, bytesOut: Int64) {
        self.date = date
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Instantaneous throughput sample for the live 60-second chart.
public struct LiveSamplePoint: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let bytesInPerSec: Double
    public let bytesOutPerSec: Double

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        bytesInPerSec: Double,
        bytesOutPerSec: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bytesInPerSec = bytesInPerSec
        self.bytesOutPerSec = bytesOutPerSec
    }
}

/// Time range filter presets for historical reporting.
public enum DateRangePreset: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case year
    case all
    case custom

    public var id: String { rawValue }

    /// Computes `[startDate, endDate]` bounds using the given calendar and reference date.
    public func dateBounds(
        now: Date = Date(),
        customStart: Date = Date(),
        customEnd: Date = Date(),
        calendar: Calendar = .current
    ) -> (from: Date?, to: Date?) {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, now)
        case .week:
            let startOfToday = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return (start, now)
        case .month:
            let startOfToday = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return (start, now)
        case .year:
            let startOfToday = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -364, to: startOfToday) ?? startOfToday
            return (start, now)
        case .all:
            return (nil, nil)
        case .custom:
            let s = min(calendar.startOfDay(for: customStart), customEnd)
            let endDayStart = calendar.startOfDay(for: max(customStart, customEnd))
            let e = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDayStart) ?? customEnd
            return (s, e)
        }
    }

    /// Recommended chart bucket granularity for this preset.
    public func defaultGranularity(customStart: Date = Date(), customEnd: Date = Date()) -> ChartGranularity {
        switch self {
        case .today:
            return .hour
        case .week, .month:
            return .day
        case .year:
            return .month
        case .all:
            return .month
        case .custom:
            let days = abs(customEnd.timeIntervalSince(customStart)) / 86400
            if days <= 2 { return .hour }
            if days <= 60 { return .day }
            if days <= 180 { return .week }
            return .month
        }
    }
}

/// Bucketing granularity for the traffic-over-time chart.
public enum ChartGranularity: String, CaseIterable, Identifiable, Sendable {
    case hour
    case day
    case week
    case month

    public var id: String { rawValue }
}

/// Sort orders for the per-app usage list.
public enum AppSortOrder: String, CaseIterable, Identifiable, Sendable {
    case totalDesc
    case downloadDesc
    case uploadDesc
    case liveDesc
    case nameAsc

    public var id: String { rawValue }
}
