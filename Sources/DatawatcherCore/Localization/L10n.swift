import Foundation
import Combine

/// Supported UI languages for Datawatcher.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case en
    case es

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .en: return "EN"
        case .es: return "ES"
        }
    }

    public var displayName: String {
        switch self {
        case .en: return "English"
        case .es: return "Español"
        }
    }
}

/// Exhaustive set of localized UI strings.
public enum L10nKey: CaseIterable, Sendable {
    // App & Header
    case appName
    case monitoringActive
    case monitoringPaused
    case pause
    case resume
    case settings
    case exportCSV
    case languageLabel

    // Date Presets
    case presetToday
    case presetWeek
    case presetMonth
    case presetYear
    case presetAll
    case presetCustom
    case customRangeTitle
    case fromDate
    case toDate
    case applyRange

    // Filters & Controls
    case includeSystem
    case allAppsFilter
    case clearFilter
    case filteredByApp
    case searchAppsPlaceholder
    case sortBy
    case sortTotalDesc
    case sortDownloadDesc
    case sortUploadDesc
    case sortLiveDesc
    case sortNameAsc

    // KPI Cards
    case kpiDownload
    case kpiUpload
    case kpiTotal
    case kpiLiveSpeed
    case kpiDownloadSubtitle
    case kpiUploadSubtitle
    case kpiTotalSubtitle
    case kpiLiveSubtitle

    // Charts
    case chartTrafficTitle
    case chartTrafficSubtitle
    case chartTopAppsMode
    case chartLiveMode
    case chartTopAppsTitle
    case chartLiveTitle
    case chartOtherApps
    case chartDownloadLegend
    case chartUploadLegend
    case chartNoData
    case chartNoDataSubtitle
    case chartGranularityHour
    case chartGranularityDay
    case chartGranularityWeek
    case chartGranularityMonth

    // App List
    case appListTitle
    case appListCountSuffix
    case columnApp
    case columnDownload
    case columnUpload
    case columnTotal
    case columnLive
    case systemBadge
    case noAppsTitle
    case noAppsSubtitle
    case clickToFilterHint

    // Menu Bar Popover & Tray Menu
    case menuBarOpenDashboard
    case menuBarQuit
    case menuBarTodayTotal
    case menuBarTopAppsToday
    case menuBarNoTrafficYet
    case menuBarLiveNow

    // Settings
    case settingsTitle
    case settingsGeneralSection
    case settingsLanguage
    case settingsPollInterval
    case settingsSecondsSuffix
    case settingsShowSpeedMenuBar
    case settingsIncludeSystemDefault
    case settingsStorageSection
    case settingsDatabasePath
    case settingsDatabaseSize
    case settingsExportData
    case settingsClearHistory
    case settingsClearConfirmTitle
    case settingsClearConfirmMessage
    case settingsClearConfirmAction
    case settingsCancel
    case settingsDone
    case exportPanelTitle
    case exportDefaultFilename
}

/// Manages the active language and persists selection in UserDefaults.
@MainActor
public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()

    private static let defaultsKey = "datawatcher.language"

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        if let saved = userDefaults.string(forKey: Self.defaultsKey),
           let parsed = AppLanguage(rawValue: saved) {
            self.language = parsed
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            self.language = preferred.lowercased().hasPrefix("es") ? .es : .en
        }
    }

    public func text(_ key: L10nKey) -> String {
        Self.text(key, language: language)
    }

    public nonisolated static func text(_ key: L10nKey, language: AppLanguage) -> String {
        switch language {
        case .en:
            return english(key)
        case .es:
            return spanish(key)
        }
    }

    private nonisolated static func english(_ key: L10nKey) -> String {
        switch key {
        case .appName: return "Datawatcher"
        case .monitoringActive: return "Live"
        case .monitoringPaused: return "Paused"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .settings: return "Settings"
        case .exportCSV: return "Export CSV"
        case .languageLabel: return "Language"

        case .presetToday: return "Today"
        case .presetWeek: return "7 Days"
        case .presetMonth: return "30 Days"
        case .presetYear: return "1 Year"
        case .presetAll: return "All Time"
        case .presetCustom: return "Custom"
        case .customRangeTitle: return "Custom Date Range"
        case .fromDate: return "From"
        case .toDate: return "To"
        case .applyRange: return "Apply"

        case .includeSystem: return "System Processes"
        case .allAppsFilter: return "All Apps"
        case .clearFilter: return "Clear"
        case .filteredByApp: return "Filtered:"
        case .searchAppsPlaceholder: return "Search applications..."
        case .sortBy: return "Sort"
        case .sortTotalDesc: return "Highest Total"
        case .sortDownloadDesc: return "Highest Download"
        case .sortUploadDesc: return "Highest Upload"
        case .sortLiveDesc: return "Live Speed"
        case .sortNameAsc: return "Name (A–Z)"

        case .kpiDownload: return "Downloaded"
        case .kpiUpload: return "Uploaded"
        case .kpiTotal: return "Total Traffic"
        case .kpiLiveSpeed: return "Live Speed"
        case .kpiDownloadSubtitle: return "Incoming data in period"
        case .kpiUploadSubtitle: return "Outgoing data in period"
        case .kpiTotalSubtitle: return "Combined network usage"
        case .kpiLiveSubtitle: return "Current throughput"

        case .chartTrafficTitle: return "Traffic Over Time"
        case .chartTrafficSubtitle: return "Download & upload history"
        case .chartTopAppsMode: return "Top Apps"
        case .chartLiveMode: return "Live 60s"
        case .chartTopAppsTitle: return "Share by Application"
        case .chartLiveTitle: return "Real-Time Throughput"
        case .chartOtherApps: return "Other"
        case .chartDownloadLegend: return "Download"
        case .chartUploadLegend: return "Upload"
        case .chartNoData: return "No traffic recorded yet"
        case .chartNoDataSubtitle: return "Datawatcher records active Wi-Fi & Ethernet traffic locally every few seconds."
        case .chartGranularityHour: return "Hourly"
        case .chartGranularityDay: return "Daily"
        case .chartGranularityWeek: return "Weekly"
        case .chartGranularityMonth: return "Monthly"

        case .appListTitle: return "Applications"
        case .appListCountSuffix: return "apps"
        case .columnApp: return "Application"
        case .columnDownload: return "Download"
        case .columnUpload: return "Upload"
        case .columnTotal: return "Total"
        case .columnLive: return "Live"
        case .systemBadge: return "System"
        case .noAppsTitle: return "No matching applications"
        case .noAppsSubtitle: return "Adjust your date filter, search query, or wait for network activity."
        case .clickToFilterHint: return "Click an app to filter charts"

        case .menuBarOpenDashboard: return "Open Dashboard"
        case .menuBarQuit: return "Quit Datawatcher"
        case .menuBarTodayTotal: return "Today's Total"
        case .menuBarTopAppsToday: return "Top Apps Today"
        case .menuBarNoTrafficYet: return "Waiting for network activity..."
        case .menuBarLiveNow: return "Live Speed"

        case .settingsTitle: return "Settings"
        case .settingsGeneralSection: return "General"
        case .settingsLanguage: return "Interface Language"
        case .settingsPollInterval: return "Sampling Interval"
        case .settingsSecondsSuffix: return "sec"
        case .settingsShowSpeedMenuBar: return "Show live speed in menu bar"
        case .settingsIncludeSystemDefault: return "Show system processes by default"
        case .settingsStorageSection: return "Local Storage"
        case .settingsDatabasePath: return "Database Location"
        case .settingsDatabaseSize: return "Database Size"
        case .settingsExportData: return "Export Usage History (CSV)"
        case .settingsClearHistory: return "Clear All History"
        case .settingsClearConfirmTitle: return "Clear all stored traffic history?"
        case .settingsClearConfirmMessage: return "This permanently deletes all local usage statistics from the SQLite database. This action cannot be undone."
        case .settingsClearConfirmAction: return "Delete History"
        case .settingsCancel: return "Cancel"
        case .settingsDone: return "Done"
        case .exportPanelTitle: return "Export Network Usage History"
        case .exportDefaultFilename: return "datawatcher-usage.csv"
        }
    }

    private nonisolated static func spanish(_ key: L10nKey) -> String {
        switch key {
        case .appName: return "Datawatcher"
        case .monitoringActive: return "En vivo"
        case .monitoringPaused: return "Pausado"
        case .pause: return "Pausar"
        case .resume: return "Reanudar"
        case .settings: return "Ajustes"
        case .exportCSV: return "Exportar CSV"
        case .languageLabel: return "Idioma"

        case .presetToday: return "Hoy"
        case .presetWeek: return "7 días"
        case .presetMonth: return "30 días"
        case .presetYear: return "1 año"
        case .presetAll: return "Todo"
        case .presetCustom: return "Rango"
        case .customRangeTitle: return "Rango personalizado"
        case .fromDate: return "Desde"
        case .toDate: return "Hasta"
        case .applyRange: return "Aplicar"

        case .includeSystem: return "Procesos del sistema"
        case .allAppsFilter: return "Todas las apps"
        case .clearFilter: return "Limpiar"
        case .filteredByApp: return "Filtrado:"
        case .searchAppsPlaceholder: return "Buscar aplicaciones..."
        case .sortBy: return "Ordenar"
        case .sortTotalDesc: return "Mayor total"
        case .sortDownloadDesc: return "Mayor descarga"
        case .sortUploadDesc: return "Mayor subida"
        case .sortLiveDesc: return "Velocidad actual"
        case .sortNameAsc: return "Nombre (A–Z)"

        case .kpiDownload: return "Descargado"
        case .kpiUpload: return "Subido"
        case .kpiTotal: return "Consumo total"
        case .kpiLiveSpeed: return "Velocidad actual"
        case .kpiDownloadSubtitle: return "Datos recibidos en el período"
        case .kpiUploadSubtitle: return "Datos enviados en el período"
        case .kpiTotalSubtitle: return "Tráfico de red combinado"
        case .kpiLiveSubtitle: return "Tasa de transferencia actual"

        case .chartTrafficTitle: return "Tráfico en el tiempo"
        case .chartTrafficSubtitle: return "Historial de descarga y subida"
        case .chartTopAppsMode: return "Top Apps"
        case .chartLiveMode: return "En vivo 60s"
        case .chartTopAppsTitle: return "Distribución por aplicación"
        case .chartLiveTitle: return "Tráfico en tiempo real"
        case .chartOtherApps: return "Otras"
        case .chartDownloadLegend: return "Descarga"
        case .chartUploadLegend: return "Subida"
        case .chartNoData: return "Sin tráfico registrado aún"
        case .chartNoDataSubtitle: return "Datawatcher guarda localmente el tráfico Wi-Fi y Ethernet cada pocos segundos."
        case .chartGranularityHour: return "Por hora"
        case .chartGranularityDay: return "Por día"
        case .chartGranularityWeek: return "Por semana"
        case .chartGranularityMonth: return "Por mes"

        case .appListTitle: return "Aplicaciones"
        case .appListCountSuffix: return "apps"
        case .columnApp: return "Aplicación"
        case .columnDownload: return "Descarga"
        case .columnUpload: return "Subida"
        case .columnTotal: return "Total"
        case .columnLive: return "En vivo"
        case .systemBadge: return "Sistema"
        case .noAppsTitle: return "Sin aplicaciones coincidentes"
        case .noAppsSubtitle: return "Ajusta el filtro de fechas, la búsqueda o espera actividad de red."
        case .clickToFilterHint: return "Haz clic en una app para filtrar los gráficos"

        case .menuBarOpenDashboard: return "Abrir panel principal"
        case .menuBarQuit: return "Salir de Datawatcher"
        case .menuBarTodayTotal: return "Total de hoy"
        case .menuBarTopAppsToday: return "Top apps de hoy"
        case .menuBarNoTrafficYet: return "Esperando actividad de red..."
        case .menuBarLiveNow: return "Velocidad actual"

        case .settingsTitle: return "Ajustes"
        case .settingsGeneralSection: return "General"
        case .settingsLanguage: return "Idioma de la interfaz"
        case .settingsPollInterval: return "Intervalo de muestreo"
        case .settingsSecondsSuffix: return "seg"
        case .settingsShowSpeedMenuBar: return "Mostrar velocidad en la barra de menú"
        case .settingsIncludeSystemDefault: return "Mostrar procesos del sistema por defecto"
        case .settingsStorageSection: return "Almacenamiento local"
        case .settingsDatabasePath: return "Ubicación de la base de datos"
        case .settingsDatabaseSize: return "Tamaño de la base de datos"
        case .settingsExportData: return "Exportar historial (CSV)"
        case .settingsClearHistory: return "Borrar todo el historial"
        case .settingsClearConfirmTitle: return "¿Borrar todo el historial de tráfico?"
        case .settingsClearConfirmMessage: return "Esto eliminará de forma permanente todas las estadísticas locales de la base de datos SQLite. Esta acción no se puede deshacer."
        case .settingsClearConfirmAction: return "Borrar historial"
        case .settingsCancel: return "Cancelar"
        case .settingsDone: return "Listo"
        case .exportPanelTitle: return "Exportar historial de consumo de red"
        case .exportDefaultFilename: return "datawatcher-consumo.csv"
        }
    }
}

