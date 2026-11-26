import AppKit
import SwiftUI
import Combine
import DatawatcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    private var monitor: NetworkMonitor!
    private var viewModel: DashboardViewModel!
    private let l10n = LanguageManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        do {
            let database = try UsageDatabase()
            self.monitor = NetworkMonitor(database: database)
        } catch {
            // Fallback to in-memory database if disk location is unavailable
            let fallback = try! UsageDatabase(path: ":memory:")
            self.monitor = NetworkMonitor(database: fallback)
        }

        self.viewModel = DashboardViewModel(monitor: monitor)

        setupStatusItem()
        setupMainWindow()
        bindStatusItemUpdates()

        monitor.start()
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Datawatcher"
        window.minSize = NSSize(width: 920, height: 620)
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

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
        viewModel.reloadData()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    // MARK: - Tray Icon (NSStatusItem + NSPopover + Context Menu)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle.fill", accessibilityDescription: "Datawatcher")
            image?.isTemplate = true
            button.image = image
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
        Publishers.CombineLatest3(
            monitor.$totalLiveInPerSec,
            monitor.$totalLiveOutPerSec,
            monitor.$showSpeedInMenuBar
        )
        .combineLatest(monitor.$isPaused)
        .receive(on: RunLoop.main)
        .sink { [weak self] tuple, isPaused in
            let (inSpeed, outSpeed, showSpeed) = tuple
            self?.updateStatusItemTitle(inSpeed: inSpeed, outSpeed: outSpeed, showSpeed: showSpeed, isPaused: isPaused)
        }
        .store(in: &cancellables)
    }

    private func updateStatusItemTitle(inSpeed: Double, outSpeed: Double, showSpeed: Bool, isPaused: Bool) {
        guard let button = statusItem?.button else { return }
        if !showSpeed {
            button.title = ""
            return
        }
        if isPaused {
            button.title = " ❚❚"
            return
        }
        let down = ByteFormatter.formatCompactSpeed(inSpeed)
        let up = ByteFormatter.formatCompactSpeed(outSpeed)
        button.title = " ↓\(down) ↑\(up)"
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
