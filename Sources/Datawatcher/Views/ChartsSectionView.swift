import SwiftUI
import Charts
import DatawatcherCore

struct ChartsSectionView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var monitor: NetworkMonitor
    @EnvironmentObject var l10n: LanguageManager

    enum RightChartMode: String, CaseIterable, Identifiable {
        case topApps
        case live
        var id: String { rawValue }
    }

    @State private var rightMode: RightChartMode = .topApps
    @State private var hoveredBucket: TimeBucketPoint?

    private struct TrafficBarItem: Identifiable {
        let id: String
        let date: Date
        let series: String
        let bytes: Int64
    }

    private struct DonutSlice: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    private struct LiveLineItem: Identifiable {
        let id: String
        let timestamp: Date
        let series: String
        let bytesPerSec: Double
    }

    private static let palette: [Color] = [
        Color(red: 0.14, green: 0.58, blue: 0.96),
        Color(red: 0.55, green: 0.36, blue: 0.96),
        Color(red: 0.08, green: 0.72, blue: 0.65),
        Color(red: 0.96, green: 0.56, blue: 0.16),
        Color(red: 0.92, green: 0.28, blue: 0.54),
        Color(red: 0.36, green: 0.45, blue: 0.92),
        Color.secondary.opacity(0.45)
    ]

    var body: some View {
        HStack(spacing: 14) {
            trafficOverTimeCard
                .frame(maxWidth: .infinity)
            rightChartCard
                .frame(width: 345)
        }
        .frame(height: 256)
    }

    // MARK: - Traffic Over Time Card

    private var trafficOverTimeCard: some View {
        let downloadLabel = l10n.text(.chartDownloadLegend)
        let uploadLabel = l10n.text(.chartUploadLegend)
        let hasTraffic = viewModel.timeSeries.contains { $0.totalBytes > 0 }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.text(.chartTrafficTitle))
                        .font(.headline)
                    Text(granularitySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let hovered = hoveredBucket {
                    HStack(spacing: 10) {
                        Text(formatBucketLabel(hovered.date))
                            .font(.caption.weight(.semibold))
                        Text("↓ \(ByteFormatter.formatBytes(hovered.bytesIn))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.cyan)
                        Text("↑ \(ByteFormatter.formatBytes(hovered.bytesOut))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.purple)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                } else {
                    HStack(spacing: 12) {
                        legendDot(color: .cyan, label: downloadLabel)
                        legendDot(color: .purple, label: uploadLabel)
                    }
                }
            }

            if hasTraffic {
                let barItems: [TrafficBarItem] = viewModel.timeSeries.flatMap { point in
                    [
                        TrafficBarItem(id: "\(point.date.timeIntervalSince1970)-in", date: point.date, series: downloadLabel, bytes: point.bytesIn),
                        TrafficBarItem(id: "\(point.date.timeIntervalSince1970)-out", date: point.date, series: uploadLabel, bytes: point.bytesOut)
                    ]
                }

                Chart(barItems) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: calendarUnit),
                        y: .value("Bytes", item.bytes)
                    )
                    .foregroundStyle(by: .value("Direction", item.series))
                    .cornerRadius(3)
                }
                .chartForegroundStyleScale([
                    downloadLabel: Color.cyan.gradient,
                    uploadLabel: Color.purple.gradient
                ])
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(.secondary.opacity(0.25))
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(ByteFormatter.formatBytes(bytes))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 7)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(formatAxisDate(date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geometry[plotFrame].origin
                                    let xPos = location.x - origin.x
                                    if let date: Date = proxy.value(atX: xPos) {
                                        hoveredBucket = nearestBucket(to: date)
                                    }
                                case .ended:
                                    hoveredBucket = nil
                                }
                            }
                    }
                }
            } else {
                emptyChartState
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Right Card (Top Apps Donut / Live 60s)

    private var rightChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(rightMode == .topApps ? l10n.text(.chartTopAppsTitle) : l10n.text(.chartLiveTitle))
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Picker("", selection: $rightMode) {
                    Text(l10n.text(.chartTopAppsMode)).tag(RightChartMode.topApps)
                    Text(l10n.text(.chartLiveMode)).tag(RightChartMode.live)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 155)
            }

            if rightMode == .topApps {
                donutContent
            } else {
                liveChartContent
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var donutContent: some View {
        let slices = buildDonutSlices()
        let grandTotal = slices.reduce(Int64(0)) { $0 + $1.bytes }

        return Group {
            if grandTotal > 0 {
                HStack(spacing: 12) {
                    ZStack {
                        Chart(slices) { slice in
                            SectorMark(
                                angle: .value("Bytes", slice.bytes),
                                innerRadius: .ratio(0.62),
                                angularInset: 1.8
                            )
                            .foregroundStyle(slice.color)
                            .cornerRadius(4)
                        }
                        .frame(width: 148, height: 148)

                        VStack(spacing: 2) {
                            Text(ByteFormatter.formatBytes(grandTotal))
                                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                            Text(l10n.text(.kpiTotal))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(slices) { slice in
                            let pct = grandTotal > 0 ? (Double(slice.bytes) / Double(grandTotal)) * 100.0 : 0
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 8, height: 8)
                                Text(slice.label)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(String(format: "%.0f%%", pct))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                emptyChartState
            }
        }
    }

    private var liveChartContent: some View {
        let downloadLabel = l10n.text(.chartDownloadLegend)
        let uploadLabel = l10n.text(.chartUploadLegend)
        let points = monitor.liveHistory

        return Group {
            if points.count >= 2 {
                let lineItems: [LiveLineItem] = points.flatMap { p in
                    [
                        LiveLineItem(id: "\(p.id)-in", timestamp: p.timestamp, series: downloadLabel, bytesPerSec: p.bytesInPerSec),
                        LiveLineItem(id: "\(p.id)-out", timestamp: p.timestamp, series: uploadLabel, bytesPerSec: p.bytesOutPerSec)
                    ]
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        legendDot(color: .cyan, label: "\(downloadLabel): \(ByteFormatter.formatSpeed(monitor.totalLiveInPerSec))")
                        legendDot(color: .purple, label: "\(uploadLabel): \(ByteFormatter.formatSpeed(monitor.totalLiveOutPerSec))")
                    }
                    .font(.caption2.monospacedDigit())

                    Chart(lineItems) { item in
                        AreaMark(
                            x: .value("Time", item.timestamp),
                            y: .value("Speed", item.bytesPerSec)
                        )
                        .foregroundStyle(by: .value("Direction", item.series))
                        .interpolationMethod(.monotone)
                        .opacity(0.22)

                        LineMark(
                            x: .value("Time", item.timestamp),
                            y: .value("Speed", item.bytesPerSec)
                        )
                        .foregroundStyle(by: .value("Direction", item.series))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartForegroundStyleScale([
                        downloadLabel: Color.cyan,
                        uploadLabel: Color.purple
                    ])
                    .chartLegend(.hidden)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(.secondary.opacity(0.25))
                            AxisValueLabel {
                                if let speed = value.as(Double.self) {
                                    Text(ByteFormatter.formatCompactSpeed(speed) + "/s")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                emptyChartState
            }
        }
    }

    // MARK: - Helpers

    private var emptyChartState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.secondary.opacity(0.7))
            Text(l10n.text(.chartNoData))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(l10n.text(.chartNoDataSubtitle))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var calendarUnit: Calendar.Component {
        switch viewModel.currentGranularity {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private var granularitySubtitle: String {
        let base = l10n.text(.chartTrafficSubtitle)
        let gran: String
        switch viewModel.currentGranularity {
        case .hour: gran = l10n.text(.chartGranularityHour)
        case .day: gran = l10n.text(.chartGranularityDay)
        case .week: gran = l10n.text(.chartGranularityWeek)
        case .month: gran = l10n.text(.chartGranularityMonth)
        }
        return "\(base) • \(gran)"
    }

    private func formatAxisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch viewModel.currentGranularity {
        case .hour:
            formatter.dateFormat = "HH:mm"
        case .day:
            formatter.dateFormat = "d MMM"
        case .week:
            formatter.dateFormat = "d MMM"
        case .month:
            formatter.dateFormat = "MMM yy"
        }
        return formatter.string(from: date)
    }

    private func formatBucketLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch viewModel.currentGranularity {
        case .hour:
            formatter.dateFormat = "HH:00"
        case .day, .week:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case .month:
            formatter.dateFormat = "MMMM yyyy"
        }
        return formatter.string(from: date)
    }

    private func nearestBucket(to target: Date) -> TimeBucketPoint? {
        viewModel.timeSeries.min {
            abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target))
        }
    }

    private func buildDonutSlices() -> [DonutSlice] {
        let sorted = viewModel.rawSummaries.sorted { $0.totalBytes > $1.totalBytes }.filter { $0.totalBytes > 0 }
        let top6 = Array(sorted.prefix(6))
        var slices: [DonutSlice] = top6.enumerated().map { idx, item in
            DonutSlice(
                id: item.app.id,
                label: item.app.name,
                bytes: item.totalBytes,
                color: Self.palette[idx % Self.palette.count]
            )
        }
        if sorted.count > 6 {
            let otherBytes = sorted.dropFirst(6).reduce(Int64(0)) { $0 + $1.totalBytes }
            if otherBytes > 0 {
                slices.append(DonutSlice(
                    id: "__other__",
                    label: l10n.text(.chartOtherApps),
                    bytes: otherBytes,
                    color: Self.palette[6]
                ))
            }
        }
        return slices
    }
}

