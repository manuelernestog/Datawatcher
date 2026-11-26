# Datawatcher

Native macOS network usage monitor per application with local SQLite history, interactive Swift Charts, menu bar tray mode, and instant English / Spanish (`EN` / `ES`) language switching.

---

## Features / Características

- **Per-App Network Monitoring / Monitoreo por aplicación**: Tracks real-time Wi-Fi and Ethernet download & upload traffic using macOS `nettop` (`-t wifi -t wired`) and groups helper processes under their parent `.app` bundle.
- **Local Historical Database / Historial 100% local**: Stores hourly per-app totals in a local SQLite database (`~/Library/Application Support/Datawatcher/usage.sqlite`). No cloud or external servers.
- **Flexible Filters / Filtros avanzados**: Filter by **Today**, **7 Days**, **30 Days**, **1 Year**, **All Time**, or a **Custom Date Range**, search by app name/bundle ID, toggle **System Processes**, and click any app to filter the charts to that application.
- **Modern Charts / Gráficos interactivos**:
  - Stacked Download/Upload bar chart over time (hourly, daily, weekly, or monthly buckets) with hover inspection.
  - Top Applications donut chart + Live 60-second real-time throughput area chart.
- **Background Tray Mode / Modo en segundo plano (Tray Icon)**: Closing the main window hides the Dock icon and keeps monitoring quietly from the macOS menu bar (`NSStatusItem`) with live `↓ / ↑` speeds, a quick-view popover, and right-click context menu.
- **Bilingual UI / Interfaz bilingüe**: Switch between **English** and **Español** at any time from the header, menu bar popover, or settings.
- **CSV Export / Exportación CSV**: Export filtered or complete history to CSV.

---

## Build, Test & Package

```bash
# Run unit tests (Xcode)
swift test

# Run unit tests (Command Line Tools without Xcode.app)
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Build release .app bundle
chmod +x scripts/build_app.sh
./scripts/build_app.sh

# Launch the app
open build/Datawatcher.app
```

Requirements: macOS 14.0+ and Swift 6 / Xcode Command Line Tools.

