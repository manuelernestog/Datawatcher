import AppKit
import CoreServices
import SwiftUI
import Combine
import DatawatcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let mainWindowFrameAutosaveName = NSWindow.FrameAutosaveName("DatawatcherMainWindowFrame")
    private static let mainWindowFullScreenKey = "datawatcher.mainWindowFullScreen"

    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var lastStatusRenderKey: String?
    private var pendingRestoreFullScreen: Bool = false
    private var hideAfterExitingFullScreen: Bool = false

    private lazy var statusIconImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.preferringMonochrome())
        let image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle.fill", accessibilityDescription: "Datawatcher")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()

    private let stackedSpeedFont = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .medium)

    private var monitor: NetworkMonitor!
    private var viewModel: DashboardViewModel!
    private let l10n = LanguageManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        LaunchAtLoginManager.syncExecutablePathIfEnabled()

        let configuredPath = UsageDatabase.configuredDatabaseURL().path
        if let database = try? UsageDatabase(path: configuredPath) {
            self.monitor = NetworkMonitor(database: database)
        } else if let defaultDB = try? UsageDatabase() {
            self.monitor = NetworkMonitor(database: defaultDB)
        } else {
            // Fallback to in-memory database if disk location is unavailable
            let fallback = try! UsageDatabase(path: ":memory:")
            self.monitor = NetworkMonitor(database: fallback)
        }

        self.viewModel = DashboardViewModel(monitor: monitor)

        let launchedInBackground = CommandLine.arguments.contains(LaunchAtLoginManager.backgroundArgument)
            || wasLaunchedAsLoginItem()

        setupStatusItem()
        bindStatusItemUpdates()
        monitor.start()

        if launchedInBackground {
            NSApp.setActivationPolicy(.accessory)
        } else {
            setupMainWindow()
            showMainWindow()
        }
    }

    private func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let propData = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else {
            return false
        }
        return propData.enumCodeValue == DescType(keyAELaunchedAsLogInItem)
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistMainWindowFrame(mainWindow)
        monitor?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Window Management (Close to Background Tray)

    private func setupMainWindow() {
        let rootView = MainWindowView(viewModel: viewModel, monitor: monitor)
            .environmentObject(l10n)

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []

        let minContentSize = NSSize(width: 1080, height: 690)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Datawatcher"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.minSize = minContentSize
        window.contentMinSize = minContentSize
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self

        let restored = window.setFrameUsingName(Self.mainWindowFrameAutosaveName)
        if !restored {
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.center()
        } else {
            let contentSize = window.contentRect(forFrameRect: window.frame).size
            if contentSize.width < minContentSize.width || contentSize.height < minContentSize.height {
                window.setContentSize(NSSize(
                    width: max(contentSize.width, minContentSize.width),
                    height: max(contentSize.height, minContentSize.height)
                ))
            }
        }
        window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)

        pendingRestoreFullScreen = UserDefaults.standard.bool(forKey: Self.mainWindowFullScreenKey)
        self.mainWindow = window
    }

    func showMainWindow() {
        popover?.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            setupMainWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if pendingRestoreFullScreen {
            pendingRestoreFullScreen = false
            if let window = mainWindow, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
        viewModel.reloadData()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        persistMainWindowFrame(sender)
        if sender.styleMask.contains(.fullScreen) {
            hideAfterExitingFullScreen = true
            sender.toggleFullScreen(nil)
            return false
        }
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistMainWindowFrame(notification.object as? NSWindow)
    }

    func windowDidMove(_ notification: Notification) {
        persistMainWindowFrame(notification.object as? NSWindow)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.mainWindowFullScreenKey)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if hideAfterExitingFullScreen {
            hideAfterExitingFullScreen = false
            window?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } else {
            UserDefaults.standard.set(false, forKey: Self.mainWindowFullScreenKey)
            persistMainWindowFrame(window)
        }
    }

    private func persistMainWindowFrame(_ window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: Self.mainWindowFrameAutosaveName)
    }

    // MARK: - Tray Icon (NSStatusItem + NSPopover + Context Menu)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = statusIconImage
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 420)
        let popoverView = MenuBarPopoverView(
            monitor: monitor,
            onOpenDashboard: { [weak self] in
                self?.showMainWindow()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        .environmentObject(l10n)
        popover.contentViewController = NSHostingController(rootView: popoverView)
        self.popover = popover
    }

    private func bindStatusItemUpdates() {
        Publishers.CombineLatest4(
            monitor.$totalLiveInPerSec,
            monitor.$totalLiveOutPerSec,
            monitor.$showSpeedInMenuBar,
            monitor.$hideMenuBarIcon
        )
        .combineLatest(monitor.$isPaused)
        .receive(on: RunLoop.main)
        .sink { [weak self] tuple, isPaused in
            let (inSpeed, outSpeed, showSpeed, hideIcon) = tuple
            self?.updateStatusItemTitle(
                inSpeed: inSpeed,
                outSpeed: outSpeed,
                showSpeed: showSpeed,
                hideIcon: hideIcon,
                isPaused: isPaused
            )
        }
        .store(in: &cancellables)
    }

    private func updateStatusItemTitle(
        inSpeed: Double,
        outSpeed: Double,
        showSpeed: Bool,
        hideIcon: Bool,
        isPaused: Bool
    ) {
        guard let button = statusItem?.button else { return }
        let shouldShowIcon = !showSpeed || !hideIcon
        let renderKey: String

        if !showSpeed {
            renderKey = "icon-only"
            guard renderKey != lastStatusRenderKey else { return }
            button.image = statusIconImage
            button.imagePosition = .imageOnly
            button.title = ""
        } else if isPaused {
            renderKey = shouldShowIcon ? "paused:icon" : "paused:text-only"
            guard renderKey != lastStatusRenderKey else { return }
            if shouldShowIcon {
                button.image = statusIconImage
                button.imagePosition = .imageLeading
                button.title = " ❚❚"
            } else {
                button.image = nil
                button.imagePosition = .noImage
                button.title = "❚❚"
            }
        } else {
            let up = ByteFormatter.formatMenuBarSpeed(outSpeed)
            let down = ByteFormatter.formatMenuBarSpeed(inSpeed)
            renderKey = "speed:\(shouldShowIcon ? "icon" : "no-icon"):\(up)|\(down)"
            guard renderKey != lastStatusRenderKey else { return }
            button.image = makeStackedSpeedImage(up: up, down: down, showIcon: shouldShowIcon)
            button.imagePosition = .imageOnly
            button.title = ""
        }
        lastStatusRenderKey = renderKey
    }

    private func makeStackedSpeedImage(up: String, down: String, showIcon: Bool) -> NSImage {
        let barHeight: CGFloat = NSStatusBar.system.thickness > 0 ? NSStatusBar.system.thickness : 22.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: stackedSpeedFont,
            .foregroundColor: NSColor.black
        ]

        let minValueWidth = ("999 KB/s" as NSString).size(withAttributes: attrs).width
        let upValueSize = (up as NSString).size(withAttributes: attrs)
        let downValueSize = (down as NSString).size(withAttributes: attrs)
        let valueColumnWidth = ceil(max(minValueWidth, max(upValueSize.width, downValueSize.width)))

        let icon = showIcon ? statusIconImage : nil
        let iconSize = icon?.size ?? .zero
        let iconTextSpacing: CGFloat = iconSize.width > 0 ? 4.0 : 0.0
        let textX = iconSize.width + iconTextSpacing
        let valueRightX = textX + valueColumnWidth
        let totalWidth = ceil(valueRightX)

        let capHeight = stackedSpeedFont.capHeight
        let lineGap: CGFloat = 2.5
        let totalVisualHeight = 2 * capHeight + lineGap
        let bottomBaselineY = (barHeight - totalVisualHeight) / 2.0
        let topBaselineY = bottomBaselineY + capHeight + lineGap
        let bottomDrawY = bottomBaselineY + stackedSpeedFont.descender
        let topDrawY = topBaselineY + stackedSpeedFont.descender

        let image = NSImage(size: NSSize(width: totalWidth, height: barHeight), flipped: false) { _ in
            if let icon {
                icon.draw(
                    in: NSRect(
                        x: 0,
                        y: (barHeight - iconSize.height) / 2.0,
                        width: iconSize.width,
                        height: iconSize.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }

            (up as NSString).draw(at: NSPoint(x: valueRightX - upValueSize.width, y: topDrawY), withAttributes: attrs)
            (down as NSString).draw(at: NSPoint(x: valueRightX - downValueSize.width, y: bottomDrawY), withAttributes: attrs)

            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = "Datawatcher ↑ \(up) ↓ \(down)"
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            monitor.refreshTodayStats()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        popover?.performClose(sender)
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: l10n.text(.menuBarOpenDashboard),
            action: #selector(menuOpenDashboard),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let pauseItem = NSMenuItem(
            title: monitor.isPaused ? l10n.text(.resume) : l10n.text(.pause),
            action: #selector(menuTogglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: l10n.text(.menuBarQuit),
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuOpenDashboard() {
        showMainWindow()
    }

    @objc private func menuTogglePause() {
        monitor.togglePause()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Standard Application Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Datawatcher", action: #selector(menuOpenDashboard), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Datawatcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
