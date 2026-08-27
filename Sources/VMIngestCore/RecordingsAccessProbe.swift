// RecordingsAccessProbe.swift — bounded-time probe for Full Disk Access.
//
// The menu-bar app needs to know whether it can read the Voice Memos container,
// but the check — listing an iCloud group container the process may not have
// TCC access to — can hang on a wedged bird/TCC daemon instead of failing
// fast. A main-thread hang while a status-item menu is tracking freezes
// keyboard input system-wide (the app holds the input grab and stops pumping
// events), so the probe must never block its caller: the listing runs on a GCD
// thread and is raced against a deadline.

import Foundation
import Synchronization

/// Runs a blocking, non-cancellable closure off the Swift cooperative pool
/// with a deadline. Synchronous file I/O cannot be interrupted, so on timeout
/// the closure's thread is abandoned to finish (or hang) in the background and
/// the fallback value is returned instead.
public enum BlockingWork {
    /// Returns `operation()`'s value if it completes within `timeout`,
    /// otherwise `fallback`. A late completion is discarded.
    ///
    /// This deliberately avoids `withTaskGroup`: the group awaits all children
    /// at scope exit, so a hung child would defeat the deadline. Instead a
    /// single continuation is resumed by whichever side finishes first.
    public static func value<T: Sendable>(
        within timeout: Duration,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        let resumed = Mutex(false)
        return await withCheckedContinuation { continuation in
            let resume: @Sendable (T) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .utility).async { resume(operation()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval) {
                resume(fallback)
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// Probes whether the process can read the Voice Memos container, i.e. whether
/// Full Disk Access is granted. There is no API to request or query FDA, so we
/// test it: with the grant the Recordings dir lists and contains the fixed
/// `CloudRecordings.db`; without it the listing comes back empty or throws
/// "Operation not permitted".
public enum RecordingsAccessProbe {
    /// A timeout reads as "no access" — at worst the warning icon is briefly
    /// wrong, and it self-corrects on the next probe. Never wrongly blocks
    /// anything: callers treat the result as advisory UI state only.
    public static func probe(
        recordingsDir: String,
        timeout: Duration = .milliseconds(500)
    ) async -> Bool {
        await BlockingWork.value(within: timeout, fallback: false) {
            directoryHoldsDatabase(recordingsDir)
        }
    }

    /// Retry schedule for the probe at launch (~34s of attempts, front-loaded).
    /// Long, because this is the case that needs the patience: the app is
    /// started by launchd at login, when the iCloud group container is cold and
    /// the system is busy, so the first listing can blow the deadline even with
    /// the grant firmly in place.
    public static let startupRetryDelays: [Duration] = [
        .seconds(1), .seconds(3), .seconds(5), .seconds(10), .seconds(15),
    ]

    /// Retry schedule for routine re-probes: one confirming attempt, so a
    /// single slow listing can't raise the warning on its own.
    public static let confirmRetryDelays: [Duration] = [.seconds(2)]

    /// Probes until access is confirmed, returning `true` as soon as any
    /// attempt succeeds and `false` once `retryDelays` is exhausted.
    ///
    /// A negative probe is ambiguous — TCC denial, a missing container, and a
    /// listing that merely overran the deadline all read as `false` — so a lone
    /// negative is not worth acting on. Retrying separates a slow first listing
    /// from a genuinely missing grant. `sleep` is injectable so tests can drive
    /// the schedule without waiting on it; a cancelled sleep ends the attempts.
    public static func probeUntilGranted(
        recordingsDir: String,
        timeout: Duration = .milliseconds(500),
        retryDelays: [Duration] = RecordingsAccessProbe.startupRetryDelays,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        if await probe(recordingsDir: recordingsDir, timeout: timeout) { return true }
        for delay in retryDelays {
            do { try await sleep(delay) } catch { return false }
            if await probe(recordingsDir: recordingsDir, timeout: timeout) { return true }
        }
        return false
    }

    static func directoryHoldsDatabase(_ dir: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return entries.contains("CloudRecordings.db")
    }
}
