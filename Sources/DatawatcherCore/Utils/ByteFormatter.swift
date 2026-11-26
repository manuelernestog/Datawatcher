import Foundation

/// Formats byte counts and transfer speeds in human-readable units.
public enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    private static let compactUnits = ["B", "K", "M", "G", "T", "P"]

    /// Formats a byte count (e.g., `1.42 GB`, `340 MB`, `12.5 KB`, `0 B`).
    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let value = Double(bytes)
        var unitIndex = 0
        var scaled = value
        while scaled >= 1024.0 && unitIndex < units.count - 1 {
            scaled /= 1024.0
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        if scaled >= 100 {
            return String(format: "%.0f %@", scaled, units[unitIndex])
        } else if scaled >= 10 {
            return String(format: "%.1f %@", scaled, units[unitIndex])
        } else {
            return String(format: "%.2f %@", scaled, units[unitIndex])
        }
    }

    /// Formats a transfer rate in bytes per second (e.g., `2.4 MB/s`, `0 B/s`).
    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec <= 0.5 { return "0 B/s" }
        var unitIndex = 0
        var scaled = bytesPerSec
        while scaled >= 1024.0 && unitIndex < units.count - 1 {
            scaled /= 1024.0
            unitIndex += 1
        }
        if unitIndex == 0 {
            return String(format: "%.0f B/s", scaled)
        }
        if scaled >= 100 {
            return String(format: "%.0f %@/s", scaled, units[unitIndex])
        } else if scaled >= 10 {
            return String(format: "%.1f %@/s", scaled, units[unitIndex])
        } else {
            return String(format: "%.2f %@/s", scaled, units[unitIndex])
        }
    }

    /// Formats a compact transfer rate for the menu bar status item (e.g., `1.2M`, `450K`, `0B`).
    public static func formatCompactSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1 { return "0B" }
        var unitIndex = 0
        var scaled = bytesPerSec
        while scaled >= 1024.0 && unitIndex < compactUnits.count - 1 {
            scaled /= 1024.0
            unitIndex += 1
        }
        if unitIndex == 0 {
            return String(format: "%.0fB", scaled)
        }
        if scaled >= 100 {
            return String(format: "%.0f%@", scaled, compactUnits[unitIndex])
        } else {
            return String(format: "%.1f%@", scaled, compactUnits[unitIndex])
        }
    }

    /// Formats a menu bar transfer rate with a space and full unit per second,
    /// using KB/s as the minimum unit (e.g., `0 KB/s`, `1 KB/s`, `42 KB/s`, `1.5 MB/s`).
    public static func formatMenuBarSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec <= 0.5 { return "0 KB/s" }

        let kb = bytesPerSec / 1024.0
        if kb < 1024.0 {
            let roundedKB = Int(kb.rounded())
            if roundedKB >= 1024 {
                return "1.0 MB/s"
            }
            return "\(roundedKB) KB/s"
        }

        var unitIndex = 2 // "MB"
        var scaled = kb / 1024.0
        while scaled >= 1024.0 && unitIndex < units.count - 1 {
            scaled /= 1024.0
            unitIndex += 1
        }
        if scaled >= 1023.5 && unitIndex < units.count - 1 {
            scaled /= 1024.0
            unitIndex += 1
        }
        if scaled >= 99.95 {
            return String(format: "%.0f %@/s", scaled, units[unitIndex])
        } else {
            return String(format: "%.1f %@/s", scaled, units[unitIndex])
        }
    }
}

