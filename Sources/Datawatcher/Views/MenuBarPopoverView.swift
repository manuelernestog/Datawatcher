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

                Picker("", selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.shortLabel).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 74)
            }

            // Live Speed & Today Total
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.text(.menuBarLiveNow))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("↓ \(ByteFormatter.formatSpeed(monitor.totalLiveInPerSec))")
                            .foregroundStyle(.cyan)
                        Text("↑ \(ByteFormatter.formatSpeed(monitor.totalLiveOutPerSec))")
                            .foregroundStyle(.purple)
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .trailing, spacing: 3) {
                    Text(l10n.text(.menuBarTodayTotal))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(ByteFormatter.formatBytes(monitor.todayTotalIn + monitor.todayTotalOut))
                        .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Top 5 Apps Today
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.text(.menuBarTopAppsToday))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

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
            HStack(spacing: 8) {
                Button {
                    onOpenDashboard()
                } label: {
                    Label(l10n.text(.menuBarOpenDashboard), systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    monitor.togglePause()
                } label: {
                    Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .help(monitor.isPaused ? l10n.text(.resume) : l10n.text(.pause))

                Button {
                    onQuit()
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.bordered)
                .help(l10n.text(.menuBarQuit))
            }
        }
        .padding(14)
        .frame(width: 340, height: 420)
    }
}

