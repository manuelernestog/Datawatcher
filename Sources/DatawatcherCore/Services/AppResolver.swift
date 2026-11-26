import Foundation
import AppKit
import Darwin

/// Resolves running process IDs to their parent macOS application bundle and display metadata.
public final class AppResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var pidCache: [Int32: (record: AppRecord, resolvedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 30.0

    public init() {}

    /// Resolves a `(pid, fallbackName)` pair into a canonical `AppRecord`.
    /// Helper processes inside an `.app` bundle (e.g. Chrome Helper) are grouped under the outermost `.app`.
    public func resolve(pid: Int32, fallbackName: String) -> AppRecord {
        let now = Date()
        lock.lock()
        if let cached = pidCache[pid], now.timeIntervalSince(cached.resolvedAt) < cacheTTL {
            lock.unlock()
            return cached.record
        }
        lock.unlock()

        let record = performResolve(pid: pid, fallbackName: fallbackName)

        lock.lock()
        pidCache[pid] = (record, now)
        if pidCache.count > 1024 {
            pidCache = pidCache.filter { now.timeIntervalSince($0.value.resolvedAt) < cacheTTL }
        }
        lock.unlock()

        return record
    }

    private func performResolve(pid: Int32, fallbackName: String) -> AppRecord {
        let execPath = executablePath(for: pid)

        if let execPath, let outerAppURL = outermostAppBundleURL(fromExecutablePath: execPath) {
            let bundle = Bundle(url: outerAppURL)
            let bundleId = bundle?.bundleIdentifier
            let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? outerAppURL.deletingPathExtension().lastPathComponent
            let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = cleanName.isEmpty ? outerAppURL.deletingPathExtension().lastPathComponent : cleanName
            let appPath = outerAppURL.path
            let isSys = isSystemPath(appPath, hasAppBundle: true)
            let id = bundleId ?? appPath

            return AppRecord(
                id: id,
                name: finalName,
                bundleId: bundleId,
                appPath: appPath,
                isSystem: isSys
            )
        }

        if let runningApp = NSRunningApplication(processIdentifier: pid),
           let bundleURL = runningApp.bundleURL {
            let outerURL = outermostAppBundleURL(fromExecutablePath: bundleURL.path) ?? bundleURL
            let bundle = Bundle(url: outerURL)
            let bundleId = runningApp.bundleIdentifier ?? bundle?.bundleIdentifier
            let name = runningApp.localizedName
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? outerURL.deletingPathExtension().lastPathComponent
            let appPath = outerURL.path
            let isSys = isSystemPath(appPath, hasAppBundle: true)
            return AppRecord(
                id: bundleId ?? appPath,
                name: name,
                bundleId: bundleId,
                appPath: appPath,
                isSystem: isSys
            )
        }

        let cleanFallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanFallback.isEmpty ? "pid-\(pid)" : cleanFallback
        let isSys = execPath.map { isSystemPath($0, hasAppBundle: false) } ?? true

        return AppRecord(
            id: "proc:\(displayName)",
            name: displayName,
            bundleId: nil,
            appPath: execPath,
            isSystem: isSys
        )
    }

    private func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Walks path components from root to find the outermost `.app` directory.
    public func outermostAppBundleURL(fromExecutablePath path: String) -> URL? {
        let components = (path as NSString).pathComponents
        guard !components.isEmpty else { return nil }

        var accumulated: [String] = []
        for component in components {
            accumulated.append(component)
            if component.hasSuffix(".app") && component != ".app" {
                let joined = NSString.path(withComponents: accumulated)
                return URL(fileURLWithPath: joined)
            }
        }
        return nil
    }

    private func isSystemPath(_ path: String, hasAppBundle: Bool) -> Bool {
        if !hasAppBundle {
            return true
        }
        if path.hasPrefix("/System/Applications/") || path.hasPrefix("/Applications/") || path.hasPrefix("/Users/") {
            return false
        }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/") {
            return true
        }
        return false
    }
}

/// Caches `NSImage` icons for applications on the main actor.
@MainActor
public final class AppIconCache {
    public static let shared = AppIconCache()

    private var cache: [String: NSImage] = [:]

    private init() {}

    public func icon(for app: AppRecord) -> NSImage {
        if let cached = cache[app.id] {
            return cached
        }

        let image: NSImage
        if let path = app.appPath, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let bundleId = app.bundleId,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            image = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            let symbolName = app.isSystem ? "gearshape.2.fill" : "app.dashed"
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: app.name)
                ?? NSImage(size: NSSize(width: 32, height: 32))
        }

        image.size = NSSize(width: 32, height: 32)
        cache[app.id] = image
        return image
    }
}
