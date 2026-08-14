import UIKit

/// Loads the application's actual bundled AppIcon artwork.
///
/// Asset-catalog app icons are compiled into the bundle root with names like
/// `AppIcon60x60@2x.png`, referenced by `CFBundleIcons → CFBundlePrimaryIcon →
/// CFBundleIconFiles` in the built Info.plist. This loader resolves the
/// highest-resolution available icon and falls back to scanning the bundle
/// root when the plist route yields nothing.
public enum AppIconLoader {
    public static func loadAppIcon() -> UIImage? {
        if let fromInfoPlist = loadFromInfoPlist() {
            return fromInfoPlist
        }
        return loadFromBundleScan()
    }

    private static func loadFromInfoPlist() -> UIImage? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String]
        else { return nil }

        var best: UIImage?
        var bestPixelSize: CGFloat = 0
        for name in files {
            guard let image = UIImage(named: name) else { continue }
            let pixelSize = max(image.size.width, image.size.height) * image.scale
            if pixelSize > bestPixelSize {
                best = image
                bestPixelSize = pixelSize
            }
        }
        return best
    }

    private static func loadFromBundleScan() -> UIImage? {
        let bundlePath = Bundle.main.bundlePath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: bundlePath) else {
            return nil
        }

        var best: UIImage?
        var bestPixelSize: CGFloat = 0
        for file in files where file.hasPrefix("AppIcon") && file.hasSuffix(".png") {
            let path = (bundlePath as NSString).appendingPathComponent(file)
            guard let image = UIImage(contentsOfFile: path) else { continue }
            let pixelSize = max(image.size.width, image.size.height) * image.scale
            if pixelSize > bestPixelSize {
                best = image
                bestPixelSize = pixelSize
            }
        }
        return best
    }
}
