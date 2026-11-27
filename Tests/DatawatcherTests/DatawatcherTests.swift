import Foundation
import Testing
@testable import DatawatcherCore

@Suite("Datawatcher Core Tests")
struct DatawatcherTests {

    @Test("NettopParser parses valid CSV lines and skips malformed or header lines")
    func nettopParserParsesValidLines() {
        let sampleOutput = """
        ,bytes_in,bytes_out,
        apsd.138,5624,9341,
        Google Chrome H.4413,726402,443147,
        com.apple.Safari.999,1024,2048,
        malformed_line_without_commas
        no_pid,100,200,
        """

        let samples = NettopParser.parse(sampleOutput)
        #expect(samples.count == 3)
        #expect(samples[0] == RawProcessSample(processName: "apsd", pid: 138, bytesIn: 5624, bytesOut: 9341))
        #expect(samples[1] == RawProcessSample(processName: "Google Chrome H", pid: 4413, bytesIn: 726402, bytesOut: 443147))
        #expect(samples[2] == RawProcessSample(processName: "com.apple.Safari", pid: 999, bytesIn: 1024, bytesOut: 2048))
    }

    @Test("DeltaTracker establishes baseline on first ingest and avoids spikes on drops or new PIDs")
    func deltaTrackerBaselineAndResets() {
        var tracker = DeltaTracker()

        let baseline = [
            RawProcessSample(processName: "Safari", pid: 100, bytesIn: 5000, bytesOut: 1000),
            RawProcessSample(processName: "Slack", pid: 200, bytesIn: 2000, bytesOut: 500)
        ]
        #expect(tracker.ingest(baseline).isEmpty)
        #expect(tracker.hasBaseline)

        // Slack's counter drops (simulating a closed socket) -> must emit 0, NOT 300.
        // Chrome appears for the first time with accumulated bytes -> must establish baseline, NOT spike 1200.
        let second = [
            RawProcessSample(processName: "Safari", pid: 100, bytesIn: 8500, bytesOut: 1400),
            RawProcessSample(processName: "Slack", pid: 200, bytesIn: 300, bytesOut: 100),
            RawProcessSample(processName: "Chrome", pid: 300, bytesIn: 1200, bytesOut: 600)
        ]
        let deltas = tracker.ingest(second)
        #expect(deltas.count == 1)

        let byPid = Dictionary(uniqueKeysWithValues: deltas.map { ($0.pid, $0) })
        #expect(byPid[100]?.deltaIn == 3500)
        #expect(byPid[100]?.deltaOut == 400)
        #expect(byPid[200] == nil)
        #expect(byPid[300] == nil)

        // Third tick: Slack recovers from new baseline 300->500, Chrome grows 1200->1800
        let third = [
            RawProcessSample(processName: "Safari", pid: 100, bytesIn: 8500, bytesOut: 1400),
            RawProcessSample(processName: "Slack", pid: 200, bytesIn: 500, bytesOut: 250),
            RawProcessSample(processName: "Chrome", pid: 300, bytesIn: 1800, bytesOut: 900)
        ]
        let deltas3 = tracker.ingest(third)
        #expect(deltas3.count == 2)
        let byPid3 = Dictionary(uniqueKeysWithValues: deltas3.map { ($0.pid, $0) })
        #expect(byPid3[200]?.deltaIn == 200)
        #expect(byPid3[200]?.deltaOut == 150)
        #expect(byPid3[300]?.deltaIn == 600)
        #expect(byPid3[300]?.deltaOut == 300)

        tracker.reset()
        #expect(!tracker.hasBaseline)
        #expect(tracker.ingest(second).isEmpty)
    }

    @Test("NettopParser clamps negative delta values to zero per column")
    func nettopParserClampsNegativeDeltas() {
        let lines = [
            ",bytes_in,bytes_out,",
            "Safari.101,-420,1500,",
            "Slack.202,800,-120,",
            "Idle.303,-10,-20,",
            "Normal.404,250,350,"
        ]

        let deltas = NettopParser.parseDeltaFrame(lines)
        #expect(deltas.count == 3)
        let byPid = Dictionary(uniqueKeysWithValues: deltas.map { ($0.pid, $0) })
        #expect(byPid[101]?.deltaIn == 0)
        #expect(byPid[101]?.deltaOut == 1500)
        #expect(byPid[202]?.deltaIn == 800)
        #expect(byPid[202]?.deltaOut == 0)
        #expect(byPid[303] == nil)
        #expect(byPid[404]?.deltaIn == 250)
        #expect(byPid[404]?.deltaOut == 350)
    }

    @Test("NettopStreamAssembler discards frame 1 baseline, handles split chunks, and avoids double-flushing")
    func nettopStreamAssemblerDiscardsBaselineAndParsesDeltaFrames() {
        var assembler = NettopStreamAssembler()

        // Frame 1 (initial cumulative baseline) split across chunks -> must produce no delta frames
        let chunk1 = ",bytes_in,bytes_out,\nSafari.100,9999999,8888888,\n"
        #expect(assembler.append(chunk1).isEmpty)
        #expect(assembler.flushCurrentFrame() == nil)

        // Frame 2 arrives split mid-line
        let chunk2a = ",bytes_in,bytes_out,\nSafari.100,1024,"
        #expect(assembler.append(chunk2a).isEmpty)

        let chunk2b = "512,\nChrome.200,0,0,\n"
        #expect(assembler.append(chunk2b).isEmpty)

        // Flush Frame 2 burst
        let frame2 = assembler.flushCurrentFrame()
        #expect(frame2?.count == 1)
        #expect(frame2?.first == ProcessDelta(processName: "Safari", pid: 100, deltaIn: 1024, deltaOut: 512))

        // Flushing again without new header must return nil (no double-emit)
        #expect(assembler.flushCurrentFrame() == nil)

        // Frame 3 (quiet frame with 0 activity) followed directly by Frame 4 header
        let chunk3 = ",bytes_in,bytes_out,\nSafari.100,0,0,\n,bytes_in,bytes_out,\n"
        let completed = assembler.append(chunk3)
        #expect(completed.count == 1)
        #expect(completed[0].isEmpty)

        // Frame 4 flushed as quiet frame returns non-nil empty array
        let frame4 = assembler.flushCurrentFrame()
        #expect(frame4 != nil)
        #expect(frame4?.isEmpty == true)
    }

    @Test("InterfaceBandwidthReader computes safe deltas and rejects resets or unphysical jumps")
    func interfaceBandwidthDeltaSanity() {
        #expect(InterfaceBandwidthReader.computeDelta(previous: 1000, current: 2500, maxDelta: 10_000) == 1500)
        #expect(InterfaceBandwidthReader.computeDelta(previous: 5000, current: 1200, maxDelta: 10_000) == 0)
        #expect(InterfaceBandwidthReader.computeDelta(previous: 1000, current: 50_000, maxDelta: 10_000) == 0)
        #expect(InterfaceBandwidthReader.isVirtualInterface("utun5"))
        #expect(InterfaceBandwidthReader.isVirtualInterface("awdl0"))
        #expect(!InterfaceBandwidthReader.isVirtualInterface("en1"))
    }

    @Test("AppResolver detects VPN tunnel daemons and packet-tunnel appex bundles")
    func appResolverDetectsVPNTunnelProcesses() throws {
        let resolver = AppResolver()

        #expect(resolver.isVPNTunnelExecutable(executablePath: "/usr/local/bin/openvpn", fallbackName: "openvpn"))
        #expect(resolver.isVPNTunnelExecutable(executablePath: "/opt/homebrew/bin/wireguard-go", fallbackName: "wireguard-go"))
        #expect(resolver.isVPNTunnelExecutable(executablePath: nil, fallbackName: "WireGuardNetwor"))
        #expect(!resolver.isVPNTunnelExecutable(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", fallbackName: "Google Chrome"))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("datawatcher-appex-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let appexContents = tempRoot
            .appendingPathComponent("MyVPN.app/Contents/PlugIns/CustomTunnel.appex/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: appexContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.vpn.tunnel",
            "CFBundleName": "CustomTunnel",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"
            ]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: appexContents.appendingPathComponent("Info.plist"))

        let execPath = appexContents.appendingPathComponent("MacOS/CustomTunnel").path
        #expect(resolver.isVPNTunnelExecutable(executablePath: execPath, fallbackName: "CustomTunnel"))
    }

    @Test("InterfaceBandwidthReader live smoke test returns zero-speed baseline on first sample")
    func interfaceBandwidthReaderLiveSmokeTest() {
        let reader = InterfaceBandwidthReader()
        if let sample = reader.sample() {
            #expect(!sample.interfaceName.isEmpty)
            #expect(!InterfaceBandwidthReader.isVirtualInterface(sample.interfaceName))
            #expect(sample.bytesInPerSec == 0)
            #expect(sample.bytesOutPerSec == 0)
        }
    }

    @Test("AppResolver extracts outermost .app bundle for helper executables")
    func appResolverOutermostBundle() {
        let resolver = AppResolver()

        let helperPath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(resolver.outermostAppBundleURL(fromExecutablePath: helperPath)?.path == "/Applications/Google Chrome.app")

        let safariPath = "/System/Applications/Safari.app/Contents/MacOS/Safari"
        #expect(resolver.outermostAppBundleURL(fromExecutablePath: safariPath)?.path == "/System/Applications/Safari.app")

        let daemonPath = "/usr/sbin/mDNSResponder"
        #expect(resolver.outermostAppBundleURL(fromExecutablePath: daemonPath) == nil)
    }

    @Test("UsageDatabase aggregates hourly buckets, filters by date/app/system, and exports CSV")
    func usageDatabaseOperations() throws {
        let db = try UsageDatabase(path: ":memory:")

        let chrome = AppRecord(id: "com.google.Chrome", name: "Google Chrome", bundleId: "com.google.Chrome", appPath: "/Applications/Google Chrome.app", isSystem: false)
        let slack = AppRecord(id: "com.tinyspeck.slackmacgap", name: "Slack", bundleId: "com.tinyspeck.slackmacgap", appPath: "/Applications/Slack.app", isSystem: false)
        let mdns = AppRecord(id: "proc:mDNSResponder", name: "mDNSResponder", bundleId: nil, appPath: "/usr/sbin/mDNSResponder", isSystem: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let day1Hour10 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10, minute: 15))!
        let day1Hour10Later = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10, minute: 45))!
        let day2Hour14 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 14, minute: 5))!

        db.recordBatch([
            (chrome, 1000, 200),
            (mdns, 500, 100)
        ], at: day1Hour10)

        db.recordBatch([
            (chrome, 500, 50),
            (slack, 300, 100)
        ], at: day1Hour10Later)

        db.recordBatch([
            (slack, 2000, 400)
        ], at: day2Hour14)

        let userOnly = db.fetchAppSummaries(from: nil, to: nil, includeSystem: false)
        #expect(userOnly.count == 2)
        #expect(userOnly.first?.app.id == slack.id)
        #expect(userOnly.first?.bytesIn == 2300)
        #expect(userOnly.first?.bytesOut == 500)

        let withSystem = db.fetchAppSummaries(from: nil, to: nil, includeSystem: true)
        #expect(withSystem.count == 3)

        let day1Start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 0))!
        let day1End = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 23, minute: 59))!
        let day1Totals = db.fetchTotals(from: day1Start, to: day1End, appId: nil, includeSystem: false)
        #expect(day1Totals.bytesIn == 1800)
        #expect(day1Totals.bytesOut == 350)

        let day3End = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 23))!
        let series = db.fetchTimeSeries(
            from: day1Start,
            to: day3End,
            appId: nil,
            granularity: .day,
            includeSystem: false,
            calendar: calendar
        )
        #expect(series.count == 3)
        #expect(series[0].bytesIn == 1800)
        #expect(series[1].totalBytes == 0)
        #expect(series[2].bytesIn == 2000)

        let chromeSeries = db.fetchTimeSeries(
            from: day1Start,
            to: day3End,
            appId: chrome.id,
            granularity: .day,
            includeSystem: false,
            calendar: calendar
        )
        #expect(chromeSeries[0].bytesIn == 1500)
        #expect(chromeSeries[2].bytesIn == 0)

        let csv = db.exportCSV(from: nil, to: nil, appId: chrome.id, includeSystem: true)
        #expect(csv.contains("timestamp_iso,app_id,app_name,bundle_id,is_system,bytes_in,bytes_out,total_bytes"))
        #expect(csv.contains("Google Chrome"))
        #expect(!csv.contains("Slack"))

        db.clearAllData()
        #expect(db.fetchAppSummaries(from: nil, to: nil, includeSystem: true).isEmpty)
    }

    @Test("ByteFormatter produces readable byte and speed strings")
    func byteFormatterOutputs() {
        #expect(ByteFormatter.formatBytes(0) == "0 B")
        #expect(ByteFormatter.formatBytes(512) == "512 B")
        #expect(ByteFormatter.formatBytes(1536) == "1.50 KB")
        #expect(ByteFormatter.formatBytes(1_048_576) == "1.00 MB")
        #expect(ByteFormatter.formatBytes(2_684_354_560) == "2.50 GB")

        #expect(ByteFormatter.formatSpeed(0) == "0 B/s")
        #expect(ByteFormatter.formatSpeed(2048) == "2.00 KB/s")
        #expect(ByteFormatter.formatSpeedComponents(0) == ("0", "B/s"))
        #expect(ByteFormatter.formatSpeedComponents(512) == ("512", "B/s"))
        #expect(ByteFormatter.formatSpeedComponents(2048) == ("2.00", "KB/s"))
        #expect(ByteFormatter.formatSpeedComponents(15_360) == ("15.0", "KB/s"))
        #expect(ByteFormatter.formatSpeedComponents(1_572_864) == ("1.50", "MB/s"))
        #expect(ByteFormatter.formatCompactSpeed(0) == "0B")
        #expect(ByteFormatter.formatCompactSpeed(1_572_864) == "1.5M")

        #expect(ByteFormatter.formatMenuBarSpeed(0) == "0 KB/s")
        #expect(ByteFormatter.formatMenuBarSpeed(200) == "0 KB/s")
        #expect(ByteFormatter.formatMenuBarSpeed(512) == "1 KB/s")
        #expect(ByteFormatter.formatMenuBarSpeed(1024) == "1 KB/s")
        #expect(ByteFormatter.formatMenuBarSpeed(15_360) == "15 KB/s")
        #expect(ByteFormatter.formatMenuBarSpeed(1_048_575) == "1.0 MB/s")
        #expect(ByteFormatter.formatMenuBarSpeed(1_572_864) == "1.5 MB/s")
        #expect(ByteFormatter.formatMenuBarSpeed(125_829_120) == "120 MB/s")
    }

    @Test("All localization keys have non-empty English and Spanish strings")
    func localizationCoverage() {
        for key in L10nKey.allCases {
            let en = LanguageManager.text(key, language: .en)
            let es = LanguageManager.text(key, language: .es)
            #expect(!en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!es.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("Live nettop snapshot and AppResolver work on current macOS host")
    func liveNettopSmokeTest() {
        let output = NetworkMonitor.runNettopSnapshot()
        let samples = NettopParser.parse(output)
        #expect(!output.isEmpty)
        #expect(!samples.isEmpty)
        let resolver = AppResolver()
        if let first = samples.first {
            let resolved = resolver.resolve(pid: first.pid, fallbackName: first.processName)
            #expect(!resolved.name.isEmpty)
        }
    }

    @Test("UsageDatabase relocates, switches to existing, and overwrites safely")
    func usageDatabaseRelocation() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("datawatcher-db-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dirA = tempRoot.appendingPathComponent("dirA", isDirectory: true)
        let dirB = tempRoot.appendingPathComponent("dirB", isDirectory: true)
        let dirC = tempRoot.appendingPathComponent("dirC", isDirectory: true)
        let urlA = dirA.appendingPathComponent(UsageDatabase.databaseFilename)
        let urlB = dirB.appendingPathComponent(UsageDatabase.databaseFilename)
        let urlC = dirC.appendingPathComponent(UsageDatabase.databaseFilename)

        let appA = AppRecord(id: "app.a", name: "App A", bundleId: "app.a", appPath: nil, isSystem: false)
        let appC = AppRecord(id: "app.c", name: "App C", bundleId: "app.c", appPath: nil, isSystem: false)

        let db = try UsageDatabase(path: urlA.path)
        db.recordBatch([(appA, 1500, 300)])

        // Move to empty destination urlB
        try db.relocate(to: urlB, mode: .moveCurrent)
        #expect(db.databaseURL?.standardizedFileURL == urlB.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: urlA.path))
        #expect(FileManager.default.fileExists(atPath: urlB.path))
        #expect(db.fetchTotals(from: nil, to: nil, appId: nil, includeSystem: true).bytesIn == 1500)

        // Prepare an existing database at urlC
        do {
            let existingDB = try UsageDatabase(path: urlC.path)
            existingDB.recordBatch([(appC, 4200, 800)])
        }

        // moveCurrent should throw when destination already exists
        var threwConflict = false
        do {
            try db.relocate(to: urlC, mode: .moveCurrent)
        } catch UsageDatabase.DatabaseError.destinationAlreadyExists {
            threwConflict = true
        }
        #expect(threwConflict)

        // useExisting switches to urlC while preserving urlB
        try db.relocate(to: urlC, mode: .useExisting)
        #expect(db.databaseURL?.standardizedFileURL == urlC.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: urlB.path))
        #expect(db.fetchTotals(from: nil, to: nil, appId: nil, includeSystem: true).bytesIn == 4200)

        // Switch back to urlB and overwrite urlC with urlB's data
        try db.relocate(to: urlB, mode: .useExisting)
        try db.relocate(to: urlC, mode: .moveAndOverwrite)
        #expect(db.databaseURL?.standardizedFileURL == urlC.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: urlB.path))
        #expect(db.fetchTotals(from: nil, to: nil, appId: nil, includeSystem: true).bytesIn == 1500)
    }

    @Test("LaunchAtLoginManager writes and removes LaunchAgent plist with background flag")
    func launchAtLoginPlistManagement() throws {
        let tempAgents = FileManager.default.temporaryDirectory
            .appendingPathComponent("datawatcher-agents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempAgents) }

        #expect(!LaunchAtLoginManager.isEnabled(in: tempAgents))

        try LaunchAtLoginManager.setEnabled(true, executablePath: "/Applications/Datawatcher.app/Contents/MacOS/Datawatcher", in: tempAgents)
        #expect(LaunchAtLoginManager.isEnabled(in: tempAgents))

        let plistData = try Data(contentsOf: LaunchAtLoginManager.plistURL(in: tempAgents))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        #expect(plist?["Label"] as? String == LaunchAtLoginManager.agentLabel)
        #expect(plist?["RunAtLoad"] as? Bool == true)
        #expect(plist?["ProgramArguments"] as? [String] == [
            "/Applications/Datawatcher.app/Contents/MacOS/Datawatcher",
            LaunchAtLoginManager.backgroundArgument
        ])

        LaunchAtLoginManager.syncExecutablePathIfEnabled(executablePath: "/Users/test/Datawatcher.app/Contents/MacOS/Datawatcher", in: tempAgents)
        let updatedData = try Data(contentsOf: LaunchAtLoginManager.plistURL(in: tempAgents))
        let updatedPlist = try PropertyListSerialization.propertyList(from: updatedData, format: nil) as? [String: Any]
        #expect((updatedPlist?["ProgramArguments"] as? [String])?.first == "/Users/test/Datawatcher.app/Contents/MacOS/Datawatcher")

        try LaunchAtLoginManager.setEnabled(false, in: tempAgents)
        #expect(!LaunchAtLoginManager.isEnabled(in: tempAgents))
    }

    @Test("UsageDatabase skips redundant app metadata writes yet persists metadata changes")
    func usageDatabaseAppMetadataCacheAndUpdates() throws {
        let db = try UsageDatabase(path: ":memory:")
        let initialApp = AppRecord(id: "com.example.app", name: "Old Name", bundleId: "com.example.app", appPath: "/Applications/Old.app", isSystem: false)
        let renamedApp = AppRecord(id: "com.example.app", name: "New Name", bundleId: "com.example.app", appPath: "/Applications/New.app", isSystem: false)
        let now = Date()

        db.recordBatch([(initialApp, 100, 50)], at: now)
        db.recordBatch([(initialApp, 200, 100)], at: now)
        let firstSummary = db.fetchAppSummaries(from: nil, to: nil, includeSystem: true)
        #expect(firstSummary.count == 1)
        #expect(firstSummary[0].app.name == "Old Name")
        #expect(firstSummary[0].bytesIn == 300)
        #expect(firstSummary[0].bytesOut == 150)

        db.recordBatch([(renamedApp, 400, 200)], at: now)
        let updatedSummary = db.fetchAppSummaries(from: nil, to: nil, includeSystem: true)
        #expect(updatedSummary.count == 1)
        #expect(updatedSummary[0].app.name == "New Name")
        #expect(updatedSummary[0].app.appPath == "/Applications/New.app")
        #expect(updatedSummary[0].bytesIn == 700)
        #expect(updatedSummary[0].bytesOut == 350)
    }

    @Test("NettopStreamAssembler parses multi-frame CRLF chunks with trailing partial line")
    func nettopStreamAssemblerMultiFrameChunk() {
        var assembler = NettopStreamAssembler()
        let chunk = ",bytes_in,bytes_out,\r\nSafari.100,5000,5000,\r\n,bytes_in,bytes_out,\r\nSafari.100,120,30,\r\n,bytes_in,bytes_out,\r\nChrome.200,400,100,\r\nMail.300,50,"
        let frames = assembler.append(chunk)
        #expect(frames.count == 1)
        #expect(frames[0] == [ProcessDelta(processName: "Safari", pid: 100, deltaIn: 120, deltaOut: 30)])

        let rest = assembler.append("10,\r\n")
        #expect(rest.isEmpty)
        let flushed = assembler.flushCurrentFrame()
        #expect(flushed == [
            ProcessDelta(processName: "Chrome", pid: 200, deltaIn: 400, deltaOut: 100),
            ProcessDelta(processName: "Mail", pid: 300, deltaIn: 50, deltaOut: 10)
        ])
    }
}
