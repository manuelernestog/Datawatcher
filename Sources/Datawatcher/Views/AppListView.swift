import SwiftUI
import DatawatcherCore

struct AppListView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @EnvironmentObject var l10n: LanguageManager

    var body: some View {
        let apps = viewModel.displayedApps
        let maxBytes = max(1, apps.map(\.totalBytes).max() ?? 1)

        VStack(spacing: 0) {
            // Toolbar Header
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(l10n.text(.appListTitle))
                        .font(.headline)
                    Text("\(apps.count) \(l10n.text(.appListCountSuffix))")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .foregroundStyle(.secondary)
                }

                Text(l10n.text(.clickToFilterHint))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField(l10n.text(.searchAppsPlaceholder), text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 220)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )

                Picker(l10n.text(.sortBy), selection: $viewModel.sortOrder) {
                    Text(l10n.text(.sortTotalDesc)).tag(AppSortOrder.totalDesc)
                    Text(l10n.text(.sortDownloadDesc)).tag(AppSortOrder.downloadDesc)
                    Text(l10n.text(.sortUploadDesc)).tag(AppSortOrder.uploadDesc)
                    Text(l10n.text(.sortLiveDesc)).tag(AppSortOrder.liveDesc)
                    Text(l10n.text(.sortNameAsc)).tag(AppSortOrder.nameAsc)
                }
                .pickerStyle(.menu)
                .frame(width: 165)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.5)

            // Column Headers
            HStack(spacing: 12) {
                Text(l10n.text(.columnApp))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(l10n.text(.columnLive))
                    .frame(width: 135, alignment: .trailing)
                Text(l10n.text(.columnDownload))
                    .frame(width: 90, alignment: .trailing)
                Text(l10n.text(.columnUpload))
                    .frame(width: 90, alignment: .trailing)
                Text(l10n.text(.columnTotal))
                    .frame(width: 95, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.25))

            Divider().opacity(0.4)

            if apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "network.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text(l10n.text(.noAppsTitle))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(l10n.text(.noAppsSubtitle))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(apps) { item in
                            let isSelected = viewModel.selectedAppId == item.app.id
                            AppUsageRowView(
                                summary: item,
                                maxBytes: maxBytes,
                                isSelected: isSelected,
                                systemBadgeText: l10n.text(.systemBadge)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.toggleAppFilter(item.app)
                            }
                            .contextMenu {
                                Button {
                                    viewModel.toggleAppFilter(item.app)
                                } label: {
                                    Label(
                                        isSelected ? l10n.text(.clearFilter) : l10n.text(.filterByApp),
                                        systemImage: isSelected ? "xmark.circle" : "line.3.horizontal.decrease.circle"
                                    )
                                }

                                if let appPath = item.app.appPath {
                                    Divider()
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
                                    } label: {
                                        Label(l10n.text(.showInFinder), systemImage: "folder")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
            }
        }
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

private struct AppUsageRowView: View {
    let summary: AppUsageSummary
    let maxBytes: Int64
    let isSelected: Bool
    let systemBadgeText: String

    @State private var isHovered = false

    var body: some View {
        let ratio = maxBytes > 0 ? min(1.0, Double(summary.totalBytes) / Double(maxBytes)) : 0
        let inShare = summary.totalBytes > 0 ? Double(summary.bytesIn) / Double(summary.totalBytes) : 1.0

        VStack(spacing: 5) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: AppIconCache.shared.icon(for: summary.app))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(summary.app.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            if summary.app.isSystem {
                                Text(systemBadgeText)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }

                            if isSelected {
                                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        if let bundleId = summary.app.bundleId {
                            Text(bundleId)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Live Speed
                HStack(spacing: 6) {
                    if summary.totalLivePerSec > 1 {
                        if summary.liveInPerSec > 1 {
                            Text("↓\(ByteFormatter.formatCompactSpeed(summary.liveInPerSec))/s")
                                .foregroundStyle(.cyan)
                        }
                        if summary.liveOutPerSec > 1 {
                            Text("↑\(ByteFormatter.formatCompactSpeed(summary.liveOutPerSec))/s")
                                .foregroundStyle(.purple)
                        }
                    } else {
                        Text("—")
                            .foregroundStyle(.quaternary)
                    }
                }
                .font(.caption2.monospacedDigit())
                .frame(width: 135, alignment: .trailing)

                Text(ByteFormatter.formatBytes(summary.bytesIn))
                    .font(.system(size: 12, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)

                Text(ByteFormatter.formatBytes(summary.bytesOut))
                    .font(.system(size: 12, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)

                Text(ByteFormatter.formatBytes(summary.totalBytes))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 95, alignment: .trailing)
            }

            // Proportional dual-color usage bar
            GeometryReader { geo in
                let fullWidth = max(0, geo.size.width * ratio)
                let inWidth = fullWidth * inShare
                let outWidth = max(0, fullWidth - inWidth)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.06))
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.cyan.opacity(0.75))
                            .frame(width: inWidth)
                        Rectangle()
                            .fill(Color.purple.opacity(0.75))
                            .frame(width: outWidth)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 3)
            .padding(.leading, 34)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    isSelected
                    ? Color.accentColor.opacity(0.14)
                    : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

