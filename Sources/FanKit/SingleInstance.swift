import Foundation

/// "Only one of me", enforced with an advisory file lock.
///
/// Written after `make up` managed to start two copies of the menu bar app at
/// once: the LaunchAgent's `RunAtLoad` started one, and the script's own `open`
/// started another two milliseconds later because LaunchServices had not
/// registered the first process yet. Two identical menu bar items, two pollers,
/// two hotkey registrations.
///
/// The launcher is fixed too, but the guard belongs here as well — double
/// clicking the app while the login agent already has it running reaches the
/// same place, and no amount of care in one shell script prevents that.
///
/// A lock rather than a scan of running applications: two copies starting
/// milliseconds apart can each fail to see the other, but only one of them can
/// hold `flock`. The kernel releases it when the process ends, crash included,
/// so there is no stale lock file to reason about.
public enum SingleInstance {

    /// Holds the lock for as long as it is alive. Let it deallocate and another
    /// copy is free to start, so keep it in storage that outlives startup.
    public final class Token {
        private let descriptor: Int32

        init(descriptor: Int32) { self.descriptor = descriptor }

        deinit {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// Where the menu bar app locks. Per-user, because the app is per-user.
    public static var appLockPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FanControl/app.lock")
            .path
    }

    /// Claims the lock, or returns nil if another process already holds it.
    ///
    /// Also succeeds when the lock file cannot be created at all. An unwritable
    /// home directory is not a reason to refuse to start: the worst that
    /// follows is a duplicate menu bar item, which is a great deal better than
    /// no menu bar item.
    public static func claim(at path: String) -> Token? {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return Token(descriptor: -1) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return Token(descriptor: descriptor)
    }
}
