# AGENTS.md

Guidance for AI coding agents working on the **Datawatcher** repository.

## Project Overview

Datawatcher is a native macOS 14.0+ per-application network usage monitor built with SwiftPM (`swift-tools-version: 6.0`, `swiftLanguageModes: [.v5]`), AppKit, SwiftUI, Swift Charts, and C SQLite3.

- **Library target (`DatawatcherCore`)**: Parsing, process/bundle resolution, physical interface bandwidth sampling, SQLite persistence, launch-at-login management, formatting, and localization.
- **Executable target (`Datawatcher`)**: AppKit lifecycle (`NSApplication`, `NSStatusItem`, `NSPopover`), view model, and SwiftUI views.
- **Test target (`DatawatcherTests`)**: Unit tests written with Apple's **Swift Testing** framework (`import Testing`, `@Suite`, `@Test`, `#expect`).

## Build, Test & Packaging Commands

Run commands from the repository root (`/Volumes/Data/Temp/Datawatcher`):

```bash
# Debug build
swift build

# Unit tests (when Xcode.app is active)
swift test

# Unit tests (when only Xcode Command Line Tools are active, without Xcode.app)
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Build release .app bundle -> build/Datawatcher.app
./scripts/build_app.sh
```

> If `swift test` fails to find `Testing`, use the Command Line Tools `-Xswiftc` / `-Xlinker` flags above.

## Architecture & Module Map

### `Sources/DatawatcherCore/` (Testable Core)

- `Models/Models.swift` — Value types (`AppRecord`, `AppUsageSummary`, `TimeBucketPoint`, `LiveSamplePoint`) and query enums (`DateRangePreset`, `ChartGranularity`, `AppSortOrder`).
- `Services/NettopParser.swift` — Parses `/usr/bin/nettop -P ... -x -J bytes_in,bytes_out` CSV lines (`NettopParser`), tracks cumulative deltas (`DeltaTracker`), and incrementally frames persistent `nettop -P -d -L 0` output (`NettopStreamAssembler`).
- `Services/InterfaceBandwidthReader.swift` — Resolves the primary physical BSD interface (`SCDynamicStore` + `getifaddrs`) skipping virtual prefixes (`utun`, `ipsec`, `wg`, `lo`, `awdl`, etc.) and reads kernel byte counters via `sysctl(NET_RT_IFLIST2)`.
- `Services/AppResolver.swift` — Resolves PIDs via `proc_pidpath` and `NSRunningApplication` to the outermost `.app` bundle, flags system paths, detects L3 VPN packet-tunnel extensions/daemons (`isVPNTunnelExecutable`), and caches app icons (`AppIconCache`).
- `Services/NetworkMonitor.swift` — `@MainActor` `ObservableObject` orchestrating a persistent `nettop` `Process` on `deltaQueue` (`com.datawatcher.nettop`), handling `NSWorkspace.didWakeNotification`, filtering VPN tunnel duplicates, writing batches to `UsageDatabase`, and publishing live speeds and 60-sample `liveHistory`.
- `Services/UsageDatabase.swift` — Thread-safe SQLite3 wrapper (`WAL` mode, `SQLITE_OPEN_FULLMUTEX`, serialized on `com.datawatcher.sqlite`). Tables: `apps` and `usage_hourly (bucket_ts, app_id, bytes_in, bytes_out)` keyed by UTC hour epoch. Supports runtime `relocate(to:mode:)` and CSV export.
- `Services/LaunchAtLoginManager.swift` — Writes/removes `~/Library/LaunchAgents/com.datawatcher.app.plist` passing `--background`.
- `Localization/L10n.swift` — Exhaustive `L10nKey` enum and `@MainActor` `LanguageManager` (`en`, `es`).
- `Utils/ByteFormatter.swift` — `formatBytes`, `formatSpeed`, `formatCompactSpeed`, `formatMenuBarSpeed`.

### `Sources/Datawatcher/` (macOS App UI)

- `main.swift` — Manual `NSApplication` entry point; sets `.accessory` activation policy immediately when launched with `--background`.
- `AppDelegate.swift` — Owns `UsageDatabase`, `NetworkMonitor`, `DashboardViewModel`, main `NSWindow` (close-to-tray behavior toggling `.regular`/`.accessory`, frame & fullscreen persistence), and `NSStatusItem` + `NSPopover` + context menu.
- `DashboardViewModel.swift` — `@MainActor` state for date presets, custom date bounds, app filter, search query, sort order, and async SQLite queries.
- `Views/` — `MainWindowView.swift`, `ChartsSectionView.swift`, `AppListView.swift`, `MenuBarPopoverView.swift`, `SettingsView.swift`.

## Key Invariants & Coding Conventions

1. **Keep core logic in `DatawatcherCore`**: Put parsing, database queries, OS/kernel calls, formatting, and localization in `DatawatcherCore` so they can be unit-tested in `DatawatcherTests` without UI dependencies.
2. **Thread safety & Swift concurrency**:
   - `NetworkMonitor`, `DashboardViewModel`, `LanguageManager`, `AppIconCache`, and `AppDelegate` are `@MainActor`.
   - `nettop` I/O and frame processing run strictly on `NetworkMonitor.deltaQueue`.
   - `UsageDatabase` serializes all SQLite handle operations on its private serial `DispatchQueue`.
   - `AppResolver` protects `pidCache` and `extensionVPNCheckCache` with `NSLock`.
3. **Networking measurement accuracy**:
   - `NettopStreamAssembler` **must** discard Frame 1 (initial cumulative counters since boot) and only emit deltas from Frame 2 onward.
   - Clamp negative kernel socket-close/reset deltas to `0`; never fabricate spikes for newly appearing PIDs or counter drops.
   - Keep L3 VPN tunnel daemons/extensions excluded in per-app aggregation while reading aggregate live throughput from the physical interface (`InterfaceBandwidthReader`) so VPN traffic is not double-counted.
4. **Localization parity**: All user-facing UI strings belong in `L10nKey` with both `.en` and `.es` cases implemented in `L10n.swift` (exhaustive `switch`).
5. **UserDefaults keys** (do not rename without migration):
   - `datawatcher.language`
   - `datawatcher.pollInterval`
   - `datawatcher.showSpeedInMenuBar`
   - `datawatcher.hideMenuBarIcon`
   - `datawatcher.includeSystemByDefault`
   - `datawatcher.databasePath`
   - `datawatcher.mainWindowFullScreen`
6. **Tests**: Add or update Swift Testing cases in `Tests/DatawatcherTests/DatawatcherTests.swift` whenever modifying parsing, delta math, VPN detection, database queries/relocation, date bounds, or formatters. Verify with `swift test` before finishing.

