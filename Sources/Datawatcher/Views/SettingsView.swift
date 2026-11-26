import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DatawatcherCore

struct SettingsView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var viewModel: DashboardViewModel
    @EnvironmentObject var l10n: LanguageManager
    @Environment(\.dismiss) private var dismiss

    @State private var showClearAlert = false
    @State private var dbSizeBytes: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(l10n.text(.settingsTitle))
                    .font(.title3.weight(.bold))
                Spacer()
                Button(l10n.text(.settingsDone)) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            Form {
                Section(l10n.text(.settingsGeneralSection)) {
                    Picker(l10n.text(.settingsLanguage), selection: $l10n.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }

                    Picker(l10n.text(.settingsPollInterval), selection: $monitor.pollIntervalSeconds) {
                        Text("2 \(l10n.text(.settingsSecondsSuffix))").tag(2.0)
                        Text("3 \(l10n.text(.settingsSecondsSuffix))").tag(3.0)
                        Text("5 \(l10n.text(.settingsSecondsSuffix))").tag(5.0)
                    }

                    Toggle(l10n.text(.settingsShowSpeedMenuBar), isOn: $monitor.showSpeedInMenuBar)
                    Toggle(l10n.text(.settingsIncludeSystemDefault), isOn: $monitor.includeSystemByDefault)
                }

                Section(l10n.text(.settingsStorageSection)) {
                    LabeledContent(l10n.text(.settingsDatabasePath)) {
                        HStack(spacing: 6) {
                            Text(monitor.database.databaseURL?.path ?? ":memory:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let url = monitor.database.databaseURL {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    LabeledContent(l10n.text(.settingsDatabaseSize)) {
                        Text(ByteFormatter.formatBytes(dbSizeBytes))
                            .font(.subheadline.monospacedDigit())
                    }

                    HStack(spacing: 12) {
                        Button {
                            exportAllCSV()
                        } label: {
                            Label(l10n.text(.settingsExportData), systemImage: "square.and.arrow.up")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            showClearAlert = true
                        } label: {
                            Label(l10n.text(.settingsClearHistory), systemImage: "trash")
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 420)
        .onAppear {
            dbSizeBytes = monitor.database.databaseFileSizeBytes()
        }
        .alert(l10n.text(.settingsClearConfirmTitle), isPresented: $showClearAlert) {
            Button(l10n.text(.settingsCancel), role: .cancel) {}
            Button(l10n.text(.settingsClearConfirmAction), role: .destructive) {
                monitor.database.clearAllData()
                monitor.refreshTodayStats()
                viewModel.clearAppFilter()
                viewModel.reloadData()
                dbSizeBytes = monitor.database.databaseFileSizeBytes()
            }
        } message: {
            Text(l10n.text(.settingsClearConfirmMessage))
        }
    }

    private func exportAllCSV() {
        let panel = NSSavePanel()
        panel.title = l10n.text(.exportPanelTitle)
        panel.nameFieldStringValue = l10n.text(.exportDefaultFilename)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            let csv = monitor.database.exportCSV(from: nil, to: nil, appId: nil, includeSystem: true)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
