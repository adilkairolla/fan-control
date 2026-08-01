import Foundation

/// Where the running code came from.
///
/// Nothing is baked into the binaries. A generated Swift file would sit in the
/// source tree as a permanent local modification, and `git pull --ff-only` —
/// which is how updates land — refuses to run against a dirty tree. So each
/// piece records its provenance into an artefact instead: the app stamps its
/// bundle's `Info.plist` at build time, and the helper install writes a small
/// JSON file into its support directory.
///
/// Two sources rather than one on purpose. Each is authoritative for its own
/// binary, which is exactly what lets `fanctl version` show an app and a daemon
/// that have drifted apart.
public struct BuildInfo: Codable, Sendable {
    public var version: String
    public var commit: String
    public var date: String
    /// Absolute path of the checkout this was built from. The updater and the
    /// app's Update button both need it to find the source again.
    public var sourceRoot: String

    public init(version: String, commit: String, date: String, sourceRoot: String) {
        self.version = version
        self.commit = commit
        self.date = date
        self.sourceRoot = sourceRoot
    }

    /// `0.1.0 (a1b2c3d)`, or just the version when the commit is unknown —
    /// which is what a build from a tarball rather than a clone looks like.
    public var short: String {
        commit.isEmpty || commit == "unknown" ? version : "\(version) (\(commit))"
    }

    // MARK: - Sources

    public static let installedPath = "/Library/Application Support/FanControl/version.json"
    public static let helperPath = "/usr/local/libexec/fand"

    /// Written by `scripts/install.sh`. Describes `fand` and `fanctl`.
    public static func installed() -> BuildInfo? {
        guard let data = FileManager.default.contents(atPath: installedPath) else { return nil }
        return try? JSONDecoder().decode(BuildInfo.self, from: data)
    }

    /// Stamped into the app bundle by `scripts/build-app.sh`.
    public static func bundled(_ bundle: Bundle = .main) -> BuildInfo? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        return BuildInfo(
            version: version,
            commit: bundle.object(forInfoDictionaryKey: "FCSourceCommit") as? String ?? "",
            date: bundle.object(forInfoDictionaryKey: "FCSourceDate") as? String ?? "",
            sourceRoot: bundle.object(forInfoDictionaryKey: "FCSourceRoot") as? String ?? ""
        )
    }

    /// The installed app bundle read off disk — for `fanctl`, which is a bare
    /// executable and has no `Info.plist` of its own.
    public static func app(at path: String = "/Applications/FanControl.app") -> BuildInfo? {
        Bundle(path: path).flatMap(bundled)
    }

    // MARK: - Updating

    /// The one-liner that works from nothing, quoted in `--help`, the README
    /// and the app when no local checkout can be found.
    public static let bootstrapCommand =
        "curl -fsSL https://raw.githubusercontent.com/adilkairolla/fan-control/main/scripts/bootstrap.sh | bash"

    /// The updater, if the checkout this was built from still exists.
    ///
    /// Falls back to `~/.fan-control` because that is where the one-line
    /// installer puts it, and someone who used that path has never seen a
    /// source directory and has no reason to know where it is.
    public static func updateScript(sourceRoot: String? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [sourceRoot, "\(home)/.fan-control"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map { "\($0)/scripts/update.sh" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
