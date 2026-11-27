import Foundation
import AppKit
import Darwin

/// Resolves running process IDs to their parent macOS application bundle and display metadata.
public final class AppResolver: @unchecked Sendable {
    private static let knownVPNTunnelNames: Set<String> = [
        "openvpn",
        "wireguard-go",
        "wireguardnetworkextension",
        "wireguardnetwor",
        "tailscaled",
        "mullvad-daemon",
        "nordvpnd",
        "warp-svc",
        "cloudflare-warp",
        "vpnagentd",
        "openconnect",
        "charon",
        "pppd",
        "sstpc",
        "zerotier-one",
        "nebula",
        "sing-box",
        "clash",
        "mihomo"
    ]

    private struct CachedBundleInfo {
        let name: String
        let bundleId: String?
        let isSystem: Bool
    }

    private let lock = NSLock()
    private var pidCache: [Int32: (record: AppRecord, isVPNTunnel: Bool, resolvedAt: Date)] = [:]
    private var bundleInfoCache: [String: CachedBundleInfo] = [:]
    private var extensionVPNCheckCache: [String: Bool] = [:]
    private let cacheTTL: TimeInterval = 60.0

    public init() {}

    /// Resolves a `(pid, fallbackName)` pair into a canonical `AppRecord`.
    /// Helper processes inside an `.app` bundle (e.g. Chrome Helper) are grouped under the outermost `.app`.
    public func resolve(pid: Int32, fallbackName: String) -> AppRecord {
        resolveWithMetadata(pid: pid, fallbackName: fallbackName).record
    }

    /// Resolves a `(pid, fallbackName)` pair into a canonical `AppRecord` plus whether the process is
    /// an L3 VPN tunnel provider/daemon whose traffic already duplicates app sockets on `utun*`.
    public func resolveWithMetadata(pid: Int32, fallbackName: String) -> (record: AppRecord, isVPNTunnel: Bool) {
        let now = Date()
        lock.lock()
        if let cached = pidCache[pid], now.timeIntervalSince(cached.resolvedAt) < cacheTTL {
            lock.unlock()
            return (cached.record, cached.isVPNTunnel)
        }
        lock.unlock()

        let resolved = performResolve(pid: pid, fallbackName: fallbackName)

        lock.lock()
        pidCache[pid] = (resolved.record, resolved.isVPNTunnel, now)
        if pidCache.count > 1024 {
            pidCache = pidCache.filter { now.timeIntervalSince($0.value.resolvedAt) < cacheTTL }
        }
        lock.unlock()

        return resolved
    }

    /// Determines whether an executable path or fallback process name belongs to a VPN packet-tunnel
    /// extension or standalone tunnel daemon.
    public func isVPNTunnelExecutable(executablePath: String?, fallbackName: String) -> Bool {
        if let path = executablePath, let extURL = extensionBundleURL(fromExecutablePath: path) {
            let extPath = extURL.path
            lock.lock()
            let cached = extensionVPNCheckCache[extPath]
            lock.unlock()

            if let cached {
                if cached { return true }
            } else {
                let isTunnelExt = checkExtensionBundleIsVPNTunnel(extURL)
                lock.lock()
                extensionVPNCheckCache[extPath] = isTunnelExt
                lock.unlock()
                if isTunnelExt { return true }
            }
        }

        let execBase = (executablePath as NSString?)?.lastPathComponent.lowercased() ?? ""
        let cleanFallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !execBase.isEmpty && (Self.knownVPNTunnelNames.contains(execBase) || execBase.hasPrefix("wireguardnetwor")) {
            return true
        }
        if !cleanFallback.isEmpty && (Self.knownVPNTunnelNames.contains(cleanFallback) || cleanFallback.hasPrefix("wireguardnetwor")) {
            return true
        }

        return false
    }

    private func checkExtensionBundleIsVPNTunnel(_ extURL: URL) -> Bool {
        let extFilename = extURL.lastPathComponent.lowercased()
        if extFilename.contains("packettunnel") || extFilename.contains("wireguardnetworkextension") {
            return true
        }

        guard let info = Bundle(url: extURL)?.infoDictionary else {
            return false
        }

        if let nsExt = info["NSExtension"] as? [String: Any],
           let pointId = nsExt["NSExtensionPointIdentifier"] as? String,
           pointId.lowercased().contains("packet-tunnel") {
            return true
        }

        if let neInfo = info["NetworkExtension"] as? [String: Any],
           let providerClasses = neInfo["NEProviderClasses"] as? [String: Any],
           providerClasses.keys.contains(where: { $0.lowercased().contains("packet-tunnel") }) {
            return true
        }

        return false
    }

    private func extensionBundleURL(fromExecutablePath path: String) -> URL? {
        let components = (path as NSString).pathComponents
        guard !components.isEmpty else { return nil }

        var accumulated: [String] = []
        for component in components {
            accumulated.append(component)
            if (component.hasSuffix(".appex") && component != ".appex") ||
               (component.hasSuffix(".systemextension") && component != ".systemextension") {
                let joined = NSString.path(withComponents: accumulated)
                return URL(fileURLWithPath: joined)
            }
        }
        return nil
    }

    private func performResolve(pid: Int32, fallbackName: String) -> (record: AppRecord, isVPNTunnel: Bool) {
        let execPath = executablePath(for: pid)
        let isVPNTunnel = isVPNTunnelExecutable(executablePath: execPath, fallbackName: fallbackName)

        if let execPath, let outerAppURL = outermostAppBundleURL(fromExecutablePath: execPath) {
            let appPath = outerAppURL.path
            let info = cachedBundleInfo(for: outerAppURL, path: appPath)
            let id = info.bundleId ?? appPath

            let record = AppRecord(
                id: id,
                name: info.name,
                bundleId: info.bundleId,
                appPath: appPath,
                isSystem: info.isSystem
            )
            return (record, isVPNTunnel)
        }

        if let runningApp = NSRunningApplication(processIdentifier: pid),
           let bundleURL = runningApp.bundleURL {
            let outerURL = outermostAppBundleURL(fromExecutablePath: bundleURL.path) ?? bundleURL
            let appPath = outerURL.path
            let info = cachedBundleInfo(
                for: outerURL,
                path: appPath,
                fallbackName: runningApp.localizedName,
                fallbackBundleId: runningApp.bundleIdentifier
            )
            let record = AppRecord(
                id: info.bundleId ?? appPath,
                name: info.name,
                bundleId: info.bundleId,
                appPath: appPath,
                isSystem: info.isSystem
            )
            return (record, isVPNTunnel)
        }

        let cleanFallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanFallback.isEmpty ? "pid-\(pid)" : cleanFallback
        let isSys = execPath.map { isSystemPath($0, hasAppBundle: false) } ?? true

        let record = AppRecord(
            id: "proc:\(displayName)",
            name: displayName,
            bundleId: nil,
            appPath: execPath,
            isSystem: isSys
        )
        return (record, isVPNTunnel)
    }

    private func cachedBundleInfo(
        for appURL: URL,
        path: String,
        fallbackName: String? = nil,
        fallbackBundleId: String? = nil
    ) -> CachedBundleInfo {
        lock.lock()
        if let cached = bundleInfoCache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let bundle = Bundle(url: appURL)
        let bundleId = fallbackBundleId ?? bundle?.bundleIdentifier
        let rawName = fallbackName
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let cleanName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? appURL.deletingPathExtension().lastPathComponent : cleanName
        let info = CachedBundleInfo(
            name: finalName,
            bundleId: bundleId,
            isSystem: isSystemPath(path, hasAppBundle: true)
        )

        lock.lock()
        bundleInfoCache[path] = info
        if bundleInfoCache.count > 512 {
            bundleInfoCache.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        return info
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
