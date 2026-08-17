import Foundation

/// Tolerant semantic version parser/comparator used for update checks.
///
/// Handles the common FluxDL release tag shapes:
///   `2.0.1`, `v2.0.1`, `V2.0.1`, `FluxDL-v2.0.1`, `v2.0.1.12`
/// and optional pre-release/build segments (`2.0.2-beta.1`, `2.0.1+42`).
/// Extra numeric segments (e.g. `v2.0.1.123` from CI build tags) are treated
/// as build metadata and ignored during comparison.
public struct SemanticVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Pre-release label (e.g. `beta.1`). A pre-release sorts before its
    /// plain release counterpart.
    public let prerelease: String?
    /// Build metadata (e.g. CI run number). Never participates in comparison.
    public let buildMetadata: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil, buildMetadata: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata
    }

    /// Parses a version string tolerantly. Returns `nil` when no leading
    /// numeric version can be found (e.g. an empty or non-version tag).
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let versionStart = trimmed.firstIndex(where: { $0.isNumber }) else { return nil }

        let body = String(trimmed[versionStart...])
        let coreAndRest = body.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(coreAndRest[0])
        let buildMetadata = coreAndRest.count > 1 && !coreAndRest[1].isEmpty
            ? String(coreAndRest[1])
            : nil

        let segments = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericPart = String(segments[0])
        let prerelease = segments.count > 1 && !segments[1].isEmpty
            ? String(segments[1])
            : nil

        let components = numericPart.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }
        guard !components.isEmpty else { return nil }

        func leadingInt(_ raw: String) -> Int? {
            let digits = raw.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }

        guard let major = leadingInt(components[0]) else { return nil }
        let minor = components.count > 1 ? (leadingInt(components[1]) ?? 0) : 0
        let patch = components.count > 2 ? (leadingInt(components[2]) ?? 0) : 0

        // Extra numeric components (e.g. `2.0.1.123`) are build metadata.
        let resolvedBuildMetadata: String?
        if components.count > 3 {
            resolvedBuildMetadata = buildMetadata ?? components[3...].joined(separator: ".")
        } else {
            resolvedBuildMetadata = buildMetadata
        }

        self.init(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: prerelease,
            buildMetadata: resolvedBuildMetadata
        )
    }

    /// Standard `major.minor.patch` representation (build metadata omitted).
    public var display: String {
        var value = "\(major).\(minor).\(patch)"
        if let prerelease { value += "-\(prerelease)" }
        return value
    }

    public var description: String { display }

    private var releaseKey: (major: Int, minor: Int, patch: Int) { (major, minor, patch) }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.releaseKey != rhs.releaseKey {
            return lhs.major < rhs.major
                || (lhs.major == rhs.major && lhs.minor < rhs.minor)
                || (lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch < rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false       // release > pre-release
        case (_, nil): return true        // pre-release < release
        case (let l?, let r?): return l < r
        }
    }
}
