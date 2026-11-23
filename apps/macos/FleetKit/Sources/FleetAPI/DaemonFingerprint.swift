import Foundation

/// Identity of a `fleet-daemon` executable.
///
/// The daemon hashes its own file once at startup and reports that value on
/// welcome. Hashing the path again later would read an in-place overwrite and
/// hide a process that is still the previous build.
public enum DaemonFingerprint {
    /// Empty when the file cannot be read.
    public static func ofFile(at path: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ""
        }
        return fnv1a64(data)
    }

    /// FNV-1a 64, 16 lowercase hex digits. Matches `fleet_protocol::fnv1a64`.
    public static func fnv1a64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Whether the app should stop the daemon that is already listening.
public enum DaemonReplacement {
    /// A missing report is a daemon from before this field. An empty launch
    /// fingerprint means this app could not read the binary it would start,
    /// so it leaves the listening process alone.
    public static func shouldReplace(
        reportedFingerprint: String?,
        launchFingerprint: String
    ) -> Bool {
        guard !launchFingerprint.isEmpty else { return false }
        guard let reportedFingerprint, !reportedFingerprint.isEmpty else { return true }
        return reportedFingerprint != launchFingerprint
    }
}
