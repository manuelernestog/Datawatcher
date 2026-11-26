import AppKit
import DatawatcherCore

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    let launchedInBackground = CommandLine.arguments.contains(LaunchAtLoginManager.backgroundArgument)
    app.setActivationPolicy(launchedInBackground ? .accessory : .regular)
    app.run()
}
