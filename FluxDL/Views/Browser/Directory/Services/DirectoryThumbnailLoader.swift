import Foundation
import UIKit
import ImageIO

/// Async, memory-conscious image thumbnail loader for grid cells.
///
/// Fetches once per URL through the same proxy-aware session policy as the
/// rest of Directory Mode, downsamples via ImageIO to ~300 px before it ever
/// reaches the UI (full-resolution images are never decoded), and caches the
/// small thumbnails in an `NSCache`. `Task`s attached to cells via
/// `.task(id:)` are cancelled automatically by SwiftUI when cells disappear.
@MainActor
public final class DirectoryThumbnailLoader: ObservableObject {

    public static let shared = DirectoryThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let client: DirectoryHTTPClient

    public init(client: DirectoryHTTPClient = .shared) {
        self.client = client
        cache.countLimit = 128
    }

    /// Returns a downsampled thumbnail, or nil on any failure.
    public func thumbnail(for url: URL, pixelSize: CGFloat = 300) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let data: Data
        do {
            let result = try await client.fetch(url: url)
            data = result.data
        } catch {
            return nil
        }
        guard let image = downsample(data: data, pixelSize: pixelSize) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    public func clearCache() {
        cache.removeAllObjects()
    }

    /// Downsampled decode via ImageIO — no full-resolution CGImage is ever
    /// created, so memory stays flat even for multi-megapixel images.
    private func downsample(data: Data, pixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}