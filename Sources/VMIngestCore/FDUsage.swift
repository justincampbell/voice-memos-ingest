// FDUsage.swift — file-descriptor accounting and self-defense.
//
// Why this exists: the process once leaked fds slowly (~250 over a night)
// until EMFILE, at which point AppKit could no longer open its own theme and
// font files — clicking the status menu then threw mid-menu-setup, the
// half-built tracking session leaked the window server's keyboard grab, and
// every keyboard on the machine went dead until the process was killed. An
// fd-exhausted GUI process is not merely degraded; it is a system-wide hazard.
// So: raise the limit at launch, watch usage continuously, and restart the
// process (via launchd KeepAlive) long before exhaustion is reachable.

import Foundation

public enum FDUsage {
    /// Number of open file descriptors right now, counted via /dev/fd.
    /// Returns nil if /dev/fd is unreadable (should never happen in practice).
    public static func count() -> Int? {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count
    }

    /// Raise the soft RLIMIT_NOFILE toward OPEN_MAX (10240). launchd agents
    /// start with a soft limit of 256, which a long-lived server process can
    /// plausibly exhaust. Returns the resulting soft limit.
    @discardableResult
    public static func raiseLimit() -> Int {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return -1 }
        // rlim_max may be RLIM_INFINITY (a huge sentinel); min() handles both.
        let ceiling = min(rlim_t(OPEN_MAX), lim.rlim_max)
        if lim.rlim_cur < ceiling {
            lim.rlim_cur = ceiling
            setrlimit(RLIMIT_NOFILE, &lim)
            getrlimit(RLIMIT_NOFILE, &lim)
        }
        return Int(lim.rlim_cur)
    }

    public enum Verdict: Equatable, Sendable {
        /// Usage is normal.
        case ok
        /// Usage is far above any legitimate working set — record it loudly.
        case warn
        /// Usage says a leak is marching toward exhaustion — restart while
        /// restarting is still safe.
        case restart
    }

    /// Thresholds are absolute, not limit-relative: the app's true working set
    /// is a few dozen fds (pipeline temp copies + MCP sessions), so hundreds
    /// open means a leak regardless of how high the limit was raised.
    public static func verdict(count: Int, warnAt: Int = 512, restartAt: Int = 4096) -> Verdict {
        if count >= restartAt { return .restart }
        if count >= warnAt { return .warn }
        return .ok
    }
}
