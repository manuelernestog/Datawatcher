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

    @Test("DeltaTracker establishes baseline on first ingest and handles counter resets")
    func deltaTrackerBaselineAndResets() {
        var tracker = DeltaTracker()

        let baseline = [
            RawProcessSample(processName: "Safari", pid: 100, bytesIn: 5000, bytesOut: 1000),
            RawProcessSample(processName: "Slack", pid: 200, bytesIn: 2000, bytesOut: 500)
        ]
        #expect(tracker.ingest(baseline).isEmpty)
        #expect(tracker.hasBaseline)

        let second = [
            RawProcessSample(processName: "Safari", pid: 100, bytesIn: 8500, bytesOut: 1400),
            RawProcessSample(processName: "Slack", pid: 200, bytesIn: 300, bytesOut: 100),
            RawProcessSample(processName: "Chrome", pid: 300, bytesIn: 1200, bytesOut: 600)
        ]
        let deltas = tracker.ingest(second)
        #expect(deltas.count == 3)

        let byPid = Dictionary(uniqueKeysWithValues: deltas.map { ($0.pid, $0) })
        #expect(byPid[100]?.deltaIn == 3500)
        #expect(byPid[100]?.deltaOut == 400)
        #expect(byPid[200]?.deltaIn == 300)
        #expect(byPid[200]?.deltaOut == 100)
        #expect(byPid[300]?.deltaIn == 1200)
        #expect(byPid[300]?.deltaOut == 600)

        tracker.reset()
        #expect(!tracker.hasBaseline)
        #expect(tracker.ingest(second).isEmpty)
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
}
