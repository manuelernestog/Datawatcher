import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DatawatcherCore

struct MainWindowView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var monitor: NetworkMonitor
    @EnvironmentObject var l10n: LanguageManager

    @State private var showCustomRangePopover = false
    @State private var draftStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var draftEndDate = Date()
    @State private var showSettingsSheet = false

    var body: some View {
        VStack(spacing: 14) {
            headerBar
            filterBar
            kpiGrid
            ChartsSectionView(viewModel: viewModel, monitor: monitor)
            AppListView(viewModel: viewModel)
                .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 920, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(monitor: monitor, viewModel: viewModel)
                .environmentObject(l10n)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(l10n.text(.appName))
                            .font(.title3.weight(.bold))

                        HStack(spacing: 5) {
                            Circle()
                                .fill(monitor.isPaused ? Color.orange : Color.green)
                                .frame(width: 7, height: 7)
                            Text(monitor.isPaused ? l10n.text(.monitoringPaused) : l10n.text(.monitoringActive))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(monitor.isPaused ? .orange : .green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((monitor.isPaused ? Color.orange : Color.green).opacity(0.14), in: Capsule())
                    }
                }
            }

            Spacer()

            // Language EN | ES toggle
            Picker(l10n.text(.languageLabel), selection: $l10n.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.shortLabel).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)

            // Pause / Resume
            Button {
                monitor.togglePause()
            } label: {
                Label(
                    monitor.isPaused ? l10n.text(.resume) : l10n.text(.pause),
                    systemImage: monitor.isPaused ? "play.fill" : "pause.fill"
                )
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)

            // Export CSV
            Button {
                exportCSVWithPanel()
            } label: {
                Label(l10n.text(.exportCSV), systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)

            // Settings
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .help(l10n.text(.settings))
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach([DateRangePreset.today, .week, .month, .year, .all], id: \.self) { preset in
                    presetButton(preset)
                }

                Button {
                    draftStartDate = viewModel.customStartDate
                    draftEndDate = viewModel.customEndDate
                    showCustomRangePopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text(presetLabel(.custom))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(viewModel.selectedPreset == .custom ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(viewModel.selectedPreset == .custom ? .white : .primary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showCustomRangePopover, arrowEdge: .bottom) {
                    customRangePopover
                }
            }
            .padding(3)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            )

            if let appName = viewModel.selectedAppName {
                HStack(spacing: 6) {
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
            }

            Spacer()

            Toggle(isOn: $viewModel.includeSystem) {
                Text(l10n.text(.includeSystem))
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func presetButton(_ preset: DateRangePreset) -> some View {
        let isActive = viewModel.selectedPreset == preset
        return Button {
            viewModel.selectedPreset = preset
        } label: {
            Text(presetLabel(preset))
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
                .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
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

    private func exportCSVWithPanel() {
        let panel = NSSavePanel()
        panel.title = l10n.text(.exportPanelTitle)
        panel.nameFieldStringValue = l10n.text(.exportDefaultFilename)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            let csv = viewModel.generateCSVExport()
            try? csv.write(to: url, atomically: true, encoding: .utf8)
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
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
