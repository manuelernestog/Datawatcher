import SwiftUI
import DatawatcherCore

struct MenuBarPopoverView: View {
    @ObservedObject var monitor: NetworkMonitor
    @EnvironmentObject var l10n: LanguageManager

    let onOpenDashboard: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                Text(l10n.text(.appName))
                    .font(.headline)

                HStack(spacing: 4) {
                    Circle()
                        .fill(monitor.isPaused ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text(monitor.isPaused ? l10n.text(.monitoringPaused) : l10n.text(.monitoringActive))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(monitor.isPaused ? .orange : .green)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((monitor.isPaused ? Color.orange : Color.green).opacity(0.14), in: Capsule())

                Spacer()
            }

            // Live Upload & Download Speed Card
            liveSpeedCard

            // Top 5 Apps Today
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(l10n.text(.menuBarTopAppsToday))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    HStack(spacing: 4) {
                        Text("\(l10n.text(.menuBarTodayTotal)):")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(ByteFormatter.formatBytes(monitor.todayTotalIn + monitor.todayTotalOut))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }

                if monitor.topLiveApps.isEmpty {
                    Text(l10n.text(.menuBarNoTrafficYet))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                } else {
                    let maxTotal = max(1, monitor.topLiveApps.map(\.totalBytes).max() ?? 1)
                    VStack(spacing: 8) {
                        ForEach(monitor.topLiveApps) { item in
                            let ratio = min(1.0, Double(item.totalBytes) / Double(maxTotal))
                            VStack(spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(nsImage: AppIconCache.shared.icon(for: item.app))
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                                    Text(item.app.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)

                                    Spacer()

                                    if item.totalLivePerSec > 1 {
                                        Text("\(ByteFormatter.formatCompactSpeed(item.totalLivePerSec))/s")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.green)
                                    }

                                    Text(ByteFormatter.formatBytes(item.totalBytes))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                }

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.primary.opacity(0.08))
                                        Capsule()
                                            .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: max(0, geo.size.width * ratio))
                                    }
                                }
                                .frame(height: 3)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Spacer(minLength: 0)

            Divider()

            // Footer Actions
            HStack(spacing: 10) {
                Button {
                    onOpenDashboard()
                } label: {
                    Label(l10n.text(.menuBarOpenDashboard), systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                PopoverIconButton(
                    systemName: monitor.isPaused ? "play.fill" : "pause.fill",
                    tint: monitor.isPaused ? .orange : .secondary,
                    helpText: monitor.isPaused ? l10n.text(.resume) : l10n.text(.pause),
                    action: { monitor.togglePause() }
                )

                PopoverIconButton(
                    systemName: "power",
                    tint: .secondary,
                    helpText: l10n.text(.menuBarQuit),
                    action: onQuit
                )
            }
        }
        .padding(14)
        .frame(width: 356, height: 440)
    }

    private var liveSpeedCard: some View {
        let recentSamples = Array(monitor.liveHistory.suffix(36))
        let uploadSeries = recentSamples.map(\.bytesOutPerSec)
        let downloadSeries = recentSamples.map(\.bytesInPerSec)

        return HStack(spacing: 0) {
            SpeedSparklineColumn(
                title: l10n.text(.chartUploadLegend),
                iconName: "arrow.up",
                speedBytesPerSec: monitor.totalLiveOutPerSec,
                samples: uploadSeries,
                tint: .purple,
                isPaused: monitor.isPaused
            )

            Divider()
                .padding(.vertical, 8)

            SpeedSparklineColumn(
                title: l10n.text(.chartDownloadLegend),
                iconName: "arrow.down",
                speedBytesPerSec: monitor.totalLiveInPerSec,
                samples: downloadSeries,
                tint: .teal,
                isPaused: monitor.isPaused
            )
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PopoverIconButton: View {
    let systemName: String
    let tint: Color
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovering ? Color.primary : tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(helpText)
    }
}

private struct SpeedSparklineColumn: View {
    let title: String
    let iconName: String
    let speedBytesPerSec: Double
    let samples: [Double]
    let tint: Color
    let isPaused: Bool

    var body: some View {
        let components = ByteFormatter.formatSpeedComponents(speedBytesPerSec)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                    Image(systemName: iconName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 19, height: 19)

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(components.value)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(components.unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            LiveSpeedSparkline(samples: samples, tint: tint, isPaused: isPaused)
                .frame(height: 22)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveSpeedSparkline: View {
    private static let windowSize = 36

    let samples: [Double]
    let tint: Color
    let isPaused: Bool

    var body: some View {
        Canvas { context, size in
            let topInset: CGFloat = 2
            let bottomInset: CGFloat = 3
            let leftInset: CGFloat = 2
            let rightInset: CGFloat = 4
            let plotWidth = max(1, size.width - leftInset - rightInset)
            let plotHeight = max(1, size.height - topInset - bottomInset)
            let baselineY = topInset + plotHeight

            let trimmed = Array(samples.suffix(Self.windowSize))
            let padded = Array(repeating: 0.0, count: max(0, Self.windowSize - trimmed.count)) + trimmed
            let maxVal = padded.max() ?? 0
            let ceiling = maxVal > 0 ? maxVal * 1.15 : 1.0

            let points: [CGPoint] = padded.enumerated().map { idx, value in
                let x = leftInset + (CGFloat(idx) / CGFloat(max(1, padded.count - 1))) * plotWidth
                let normalized = maxVal > 0 ? min(1.0, max(0.0, value / ceiling)) : 0.0
                let y = baselineY - plotHeight * CGFloat(normalized)
                return CGPoint(x: x, y: y)
            }

            guard let first = points.first, let last = points.last else { return }

            var linePath = Path()
            linePath.move(to: first)
            for point in points.dropFirst() {
                linePath.addLine(to: point)
            }

            let lineOpacity = isPaused ? 0.45 : 0.9

            if maxVal > 0 {
                var areaPath = linePath
                areaPath.addLine(to: CGPoint(x: last.x, y: baselineY))
                areaPath.addLine(to: CGPoint(x: first.x, y: baselineY))
                areaPath.closeSubpath()

                context.fill(
                    areaPath,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(isPaused ? 0.08 : 0.16), tint.opacity(0.0)]),
                        startPoint: CGPoint(x: 0, y: topInset),
                        endPoint: CGPoint(x: 0, y: baselineY)
                    )
                )
            }

            context.stroke(
                linePath,
                with: .color(tint.opacity(lineOpacity)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )

            let dotRect = CGRect(x: last.x - 2.25, y: last.y - 2.25, width: 4.5, height: 4.5)
            context.fill(Path(ellipseIn: dotRect), with: .color(tint.opacity(lineOpacity)))
        }
    }
}

