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
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled()
    @State private var databasePath: String = ""
    @State private var isCustomDatabaseLocation = false
    @State private var pendingTargetURL: URL?
    @State private var showExistingDBAlert = false
    @State private var errorMessage: String?

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
                    Toggle(
                        l10n.text(.settingsLaunchAtLogin),
                        isOn: Binding(
                            get: { launchAtLogin },
                            set: { updateLaunchAtLogin($0) }
                        )
                    )
                }

                Section(l10n.text(.settingsStorageSection)) {
                    LabeledContent(l10n.text(.settingsDatabasePath)) {
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(databasePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(databasePath)
                                if let url = monitor.database.databaseURL {
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    } label: {
                                        Image(systemName: "folder")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            HStack(spacing: 8) {
                                Button(l10n.text(.settingsChangeLocation)) {
                                    chooseDatabaseFolder()
                                }
                                .controlSize(.small)

                                if isCustomDatabaseLocation {
                                    Button(l10n.text(.settingsResetLocation)) {
                                        resetDatabaseLocation()
                                    }
                                    .controlSize(.small)
                                }
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
        .frame(width: 520, height: 480)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager.isEnabled()
            refreshStorageState()
        }
        .alert(l10n.text(.settingsClearConfirmTitle), isPresented: $showClearAlert) {
            Button(l10n.text(.settingsCancel), role: .cancel) {}
            Button(l10n.text(.settingsClearConfirmAction), role: .destructive) {
                monitor.database.clearAllData()
                monitor.refreshTodayStats()
                viewModel.clearAppFilter()
                viewModel.reloadData()
                refreshStorageState()
            }
        } message: {
            Text(l10n.text(.settingsClearConfirmMessage))
        }
        .alert(l10n.text(.settingsDatabaseExistsTitle), isPresented: $showExistingDBAlert) {
            Button(l10n.text(.settingsDatabaseUseExisting)) {
                if let url = pendingTargetURL {
                    performDatabaseRelocation(to: url, mode: .useExisting)
                }
                pendingTargetURL = nil
            }
            Button(l10n.text(.settingsDatabaseReplaceCurrent), role: .destructive) {
                if let url = pendingTargetURL {
                    performDatabaseRelocation(to: url, mode: .moveAndOverwrite)
                }
                pendingTargetURL = nil
            }
            Button(l10n.text(.settingsCancel), role: .cancel) {
                pendingTargetURL = nil
            }
        } message: {
            Text(l10n.text(.settingsDatabaseExistsMessage))
        }
        .alert(
            l10n.text(.settingsErrorTitle),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(l10n.text(.settingsOk), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refreshStorageState() {
        dbSizeBytes = monitor.database.databaseFileSizeBytes()
        databasePath = monitor.database.databaseURL?.path ?? ":memory:"
        isCustomDatabaseLocation = UsageDatabase.isUsingCustomLocation()
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLogin = enabled
        } catch {
            launchAtLogin = LaunchAtLoginManager.isEnabled()
            errorMessage = error.localizedDescription
        }
    }

    private func chooseDatabaseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = l10n.text(.settingsChooseDatabaseFolderPrompt)
        panel.message = l10n.text(.settingsChooseDatabaseFolderMessage)
        panel.directoryURL = monitor.database.databaseURL?.deletingLastPathComponent()

        if panel.runModal() == .OK, let folderURL = panel.url {
            let targetURL = folderURL.appendingPathComponent(UsageDatabase.databaseFilename)
            requestDatabaseRelocation(to: targetURL)
        }
    }

    private func resetDatabaseLocation() {
        requestDatabaseRelocation(to: UsageDatabase.defaultDatabaseURL())
    }

    private func requestDatabaseRelocation(to targetURL: URL) {
        if targetURL.standardizedFileURL == monitor.database.databaseURL?.standardizedFileURL {
            UsageDatabase.saveConfiguredDatabaseURL(targetURL)
            refreshStorageState()
            return
        }

        if FileManager.default.fileExists(atPath: targetURL.path) {
            pendingTargetURL = targetURL
            showExistingDBAlert = true
        } else {
            performDatabaseRelocation(to: targetURL, mode: .moveCurrent)
        }
    }

    private func performDatabaseRelocation(to targetURL: URL, mode: UsageDatabase.RelocationMode) {
        do {
            try monitor.database.relocate(to: targetURL, mode: mode)
            UsageDatabase.saveConfiguredDatabaseURL(targetURL)
            monitor.refreshTodayStats()
            viewModel.clearAppFilter()
            viewModel.reloadData()
            refreshStorageState()
        } catch {
            errorMessage = error.localizedDescription
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
