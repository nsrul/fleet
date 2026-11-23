use std::fs;

/// Hash the executable this process was started from.
///
/// Computed once, before the socket accepts clients. Re-reading the path on
/// each welcome would pick up an in-place overwrite and report the new build
/// while the old code kept running.
pub fn executable_fingerprint() -> String {
    let Ok(path) = std::env::current_exe() else {
        return String::new();
    };
    let Ok(bytes) = fs::read(path) else {
        return String::new();
    };
    fleet_protocol::fnv1a64(&bytes)
}
