import Darwin
import Foundation
import OSLog

/// Keeps helper processes from outliving the app.
///
/// macOS re-parents a child to launchd when its parent is force-quit or
/// crashes, so a helper that does not watch its parent keeps running. Two
/// defenses cover that:
///
/// 1. `ChildProcessWatchdog` runs a tiny shell loop next to each helper. When
///    the app's process ID disappears, the loop terminates the helper (then
///    kills it if it ignores the request) and exits. It also exits on its own
///    as soon as the helper is gone, so it never lingers after a normal stop.
/// 2. `OrphanedHelperReaper` runs at app start and terminates helpers from an
///    earlier app instance that were already orphaned (their parent is launchd).
enum ChildProcessGuard {
    static let logger = Logger(subsystem: "org.localdictation.app", category: "ChildProcessGuard")
}

/// A watchdog shell process bound to one helper process.
@MainActor
final class ChildProcessWatchdog {
    private var process: Process?

    /// The loop polls once a second, so a helper survives at most about a second
    /// past a force-quit, plus the two-second grace period before SIGKILL.
    nonisolated static let script = """
    app="$1"; helper="$2"
    while kill -0 "$app" 2>/dev/null && kill -0 "$helper" 2>/dev/null; do sleep 1; done
    if kill -0 "$helper" 2>/dev/null && ! kill -0 "$app" 2>/dev/null; then
      kill -TERM "$helper" 2>/dev/null
      sleep 2
      kill -KILL "$helper" 2>/dev/null
    fi
    exit 0
    """

    /// Starts watching `helperProcessID` on behalf of the current app process.
    init(helperProcessID: Int32) {
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", Self.script, "watchdog", String(ProcessInfo.processInfo.processIdentifier), String(helperProcessID)]
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        do {
            try watchdog.run()
            process = watchdog
        } catch {
            ChildProcessGuard.logger.error("WATCHDOG_START_FAILED helper=\(helperProcessID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the watchdog after the helper was stopped on purpose.
    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }
}

/// Finds helper processes launched from an app bundle whose parent is gone.
enum OrphanedHelperReaper {
    /// Executable names this app launches as helpers.
    static let helperNames: Set<String> = ["nemo-speech"]

    struct Orphan: Equatable {
        let processID: pid_t
        let path: String
    }

    static func isHelper(path: String, parentProcessID: pid_t, helperNames: Set<String> = helperNames) -> Bool {
        guard parentProcessID == 1 else { return false }
        let url = URL(fileURLWithPath: path)
        guard helperNames.contains(url.lastPathComponent) else { return false }
        return path.contains("/Contents/Resources/Engine/bin/")
    }

    static func findOrphans() -> [Orphan] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 16)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }
        let live = pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
        var orphans: [Orphan] = []
        for pid in live {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if isHelper(path: path, parentProcessID: pid_t(info.pbi_ppid)) {
                orphans.append(Orphan(processID: pid, path: path))
            }
        }
        return orphans
    }

    /// Terminates orphaned helpers. Returns the process IDs it signaled.
    @discardableResult
    static func reap() -> [pid_t] {
        let orphans = findOrphans()
        for orphan in orphans {
            ChildProcessGuard.logger.warning("ORPHANED_HELPER_TERMINATED pid=\(orphan.processID, privacy: .public) path=\(orphan.path, privacy: .public)")
            Darwin.kill(orphan.processID, SIGTERM)
        }
        if !orphans.isEmpty {
            let ids = orphans.map(\.processID)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                for pid in ids { Darwin.kill(pid, SIGKILL) }
            }
        }
        return orphans.map(\.processID)
    }
}
