import Foundation

/// Single source of truth for the installed FluxDL version.
///
/// Reads directly from the app bundle's `CFBundleShortVersionString` /
/// `CFBundleVersion`, which are fed by `MARKETING_VERSION` /
/// `CURRENT_PROJECT_VERSION` in the Xcode build settings. Settings UI and the
/// update checker both use this service, so they can never drift apart.
public protocol AppVersionServiceProtocol: Sendable {
    var versionString: String { get }
    var buildString: String { get }
    var semanticVersion: SemanticVersion? { get }
}

public struct AppVersionService: AppVersionServiceProtocol {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public var versionString: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Internal build number. Kept out of every visible UI surface.
    public var buildString: String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    public var semanticVersion: SemanticVersion? {
        SemanticVersion(rawValue: versionString)
    }
}