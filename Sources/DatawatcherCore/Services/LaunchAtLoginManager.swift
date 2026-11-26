import Foundation

/// Manages the per-user LaunchAgent plist so Datawatcher can start at login in background mode.
public enum LaunchAtLoginManager {
    public static let agentLabel = "com.datawatcher.app"
    public static let backgroundArgument = "--background"

    public enum LaunchAtLoginError: Error, LocalizedError {
        case missingExecutablePath

        public var errorDescription: String? {
            switch self {
            case .missingExecutablePath:
                return "Unable to determine the Datawatcher executable path."
            }
        }
    }

    public static var defaultLaunchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static func plistURL(in directory: URL = defaultLaunchAgentsDirectory) -> URL {
        directory.appendingPathComponent("\(agentLabel).plist")
    }

    public static func isEnabled(in directory: URL = defaultLaunchAgentsDirectory) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(in: directory).path)
    }

    public static func setEnabled(
        _ enabled: Bool,
        executablePath: String? = Bundle.main.executablePath,
        in directory: URL = defaultLaunchAgentsDirectory
    ) throws {
        let fm = FileManager.default
        let url = plistURL(in: directory)

        if enabled {
            let resolvedPath = (executablePath?.isEmpty == false ? executablePath : nil)
                ?? ProcessInfo.processInfo.arguments.first
                ?? ""
            guard !resolvedPath.isEmpty else {
                throw LaunchAtLoginError.missingExecutablePath
            }

            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [resolvedPath, backgroundArgument],
                "RunAtLoad": true,
                "KeepAlive": false,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive"
            ]

            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Updates the stored executable path in the LaunchAgent plist if the app bundle was moved.
    public static func syncExecutablePathIfEnabled(
        executablePath: String? = Bundle.main.executablePath,
        in directory: URL = defaultLaunchAgentsDirectory
    ) {
        guard isEnabled(in: directory),
              let path = executablePath,
              !path.isEmpty else {
            return
        }

        let url = plistURL(in: directory)
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = plist["ProgramArguments"] as? [String],
           args.first == path {
            return
        }

        try? setEnabled(true, executablePath: path, in: directory)
    }
}

