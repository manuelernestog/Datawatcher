import SwiftUI
import AppKit
import DatawatcherCore

struct MainWindowView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var monitor: NetworkMonitor
    @EnvironmentObject var l10n: LanguageManager

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showCustomRangePopover = false
    @State private var draftStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var draftEndDate = Date()
    @State private var showSettingsSheet = false

    private static let standardPresets: [DateRangePreset] = [.today, .week, .month, .year, .all]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 640)
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(monitor: monitor, viewModel: viewModel)
                .environmentObject(l10n)
        }
    }

    // MARK: - Sidebar

    private var sidebarSelection: Binding<DateRangePreset?> {
        Binding(
            get: { viewModel.selectedPreset },
            set: { newValue in
                guard let preset = newValue else { return }
                viewModel.selectedPreset = preset
                if preset == .custom {
                    draftStartDate = viewModel.customStartDate
                    draftEndDate = viewModel.customEndDate
                    showCustomRangePopover = true
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section(l10n.text(.sidebarPeriodSection)) {
                ForEach(Self.standardPresets, id: \.self) { preset in
                    Label(presetLabel(preset), systemImage: presetIcon(preset))
                        .tag(preset)
                }

                HStack(spacing: 6) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(presetLabel(.custom))
                            if viewModel.selectedPreset == .custom {
                                Text(formattedCustomRange)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } icon: {
                        Image(systemName: presetIcon(.custom))
                    }

                    Spacer(minLength: 4)

                    if viewModel.selectedPreset == .custom {
                        Button {
                            draftStartDate = viewModel.customStartDate
                            draftEndDate = viewModel.customEndDate
                            showCustomRangePopover.toggle()
                        } label: {
                            Image(systemName: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.text(.sidebarEditRange))
                    }
                }
                .tag(DateRangePreset.custom)
                .popover(isPresented: $showCustomRangePopover, arrowEdge: .trailing) {
                    customRangePopover
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarStatusFooter
        }
        .navigationSplitViewColumnWidth(min: 195, ideal: 220, max: 255)
    }

    private var sidebarStatusFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.5)

            HStack(spacing: 9) {
                Circle()
                    .fill(monitor.isPaused ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: (monitor.isPaused ? Color.orange : Color.green).opacity(0.45), radius: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(monitor.isPaused ? l10n.text(.monitoringPaused) : l10n.text(.monitoringActive))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(monitor.isPaused ? .orange : .primary)

                    if monitor.isPaused {
                        Text(l10n.text(.appName))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("↓ \(ByteFormatter.formatCompactSpeed(monitor.totalLiveInPerSec))/s  ↑ \(ByteFormatter.formatCompactSpeed(monitor.totalLiveOutPerSec))/s")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.customRangeTitle))
                .font(.headline)

            DatePicker(l10n.text(.fromDate), selection: $draftStartDate, displayedComponents: .date)
            DatePicker(l10n.text(.toDate), selection: $draftEndDate, displayedComponents: .date)

            HStack {
                Spacer()
                Button(l10n.text(.applyRange)) {
                    viewModel.applyCustomRange(start: draftStartDate, end: draftEndDate)
                    showCustomRangePopover = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        VStack(spacing: 14) {
            if let appName = viewModel.selectedAppName {
                activeFilterBanner(appName: appName)
            }

            kpiGrid
            ChartsSectionView(viewModel: viewModel, monitor: monitor)
            AppListView(viewModel: viewModel)
                .frame(minHeight: 220, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(detailNavigationTitle)
        .navigationSubtitle(detailNavigationSubtitle)
        .toolbar {
            detailToolbar
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $viewModel.includeSystem) {
                Label(l10n.text(.includeSystem), systemImage: "cpu")
            }
            .toggleStyle(.button)
            .tint(viewModel.includeSystem ? .accentColor : nil)
            .help(viewModel.includeSystem ? l10n.text(.hideSystemProcesses) : l10n.text(.showSystemProcesses))
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                monitor.togglePause()
            } label: {
                Label(
                    monitor.isPaused ? l10n.text(.resume) : l10n.text(.pause),
                    systemImage: monitor.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .tint(monitor.isPaused ? .orange : nil)
            .help(monitor.isPaused ? l10n.text(.resume) : l10n.text(.pause))
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showSettingsSheet = true
            } label: {
                Label(l10n.text(.settings), systemImage: "gearshape")
            }
            .help(l10n.text(.settings))
        }
    }

    private func activeFilterBanner(appName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("\(l10n.text(.filteredByApp)) \(appName)")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Button {
                viewModel.clearAppFilter()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(l10n.text(.clearFilter))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .modifier(ActiveFilterPillModifier())
    }

    // MARK: - KPI Cards

    private var kpiGrid: some View {
        HStack(spacing: 12) {
            KpiCardView(
                title: l10n.text(.kpiDownload),
                value: ByteFormatter.formatBytes(viewModel.periodBytesIn),
                subtitle: l10n.text(.kpiDownloadSubtitle),
                icon: "arrow.down.circle.fill",
                tint: .cyan
            )
            KpiCardView(
                title: l10n.text(.kpiUpload),
                value: ByteFormatter.formatBytes(viewModel.periodBytesOut),
                subtitle: l10n.text(.kpiUploadSubtitle),
                icon: "arrow.up.circle.fill",
                tint: .purple
            )
            KpiCardView(
                title: l10n.text(.kpiTotal),
                value: ByteFormatter.formatBytes(viewModel.periodBytesIn + viewModel.periodBytesOut),
                subtitle: l10n.text(.kpiTotalSubtitle),
                icon: "arrow.up.arrow.down.circle.fill",
                tint: .blue
            )
            KpiCardView(
                title: l10n.text(.kpiLiveSpeed),
                value: "↓ \(ByteFormatter.formatSpeed(viewModel.filteredLiveInPerSec))",
                subtitle: "↑ \(ByteFormatter.formatSpeed(viewModel.filteredLiveOutPerSec))",
                icon: "bolt.horizontal.circle.fill",
                tint: monitor.isPaused ? .orange : .green
            )
        }
    }

    // MARK: - Helpers

    private var detailNavigationTitle: String {
        if viewModel.selectedPreset == .custom {
            return formattedCustomRange
        }
        return presetLabel(viewModel.selectedPreset)
    }

    private var detailNavigationSubtitle: String {
        let status = monitor.isPaused ? l10n.text(.monitoringPaused) : l10n.text(.monitoringActive)
        return "\(l10n.text(.appName)) • \(status)"
    }

    private var formattedCustomRange: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let start = formatter.string(from: min(viewModel.customStartDate, viewModel.customEndDate))
        let end = formatter.string(from: max(viewModel.customStartDate, viewModel.customEndDate))
        return "\(start) – \(end)"
    }

    private func presetLabel(_ preset: DateRangePreset) -> String {
        switch preset {
        case .today: return l10n.text(.presetToday)
        case .week: return l10n.text(.presetWeek)
        case .month: return l10n.text(.presetMonth)
        case .year: return l10n.text(.presetYear)
        case .all: return l10n.text(.presetAll)
        case .custom: return l10n.text(.presetCustom)
        }
    }

    private func presetIcon(_ preset: DateRangePreset) -> String {
        switch preset {
        case .today: return "clock"
        case .week: return "calendar"
        case .month: return "calendar.day.timeline.left"
        case .year: return "chart.line.uptrend.xyaxis"
        case .all: return "infinity"
        case .custom: return "calendar.badge.plus"
        }
    }
}

private struct ActiveFilterPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.16)).interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            content
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}

private struct KpiCardView: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
        )
    }
}
