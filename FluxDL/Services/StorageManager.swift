import Foundation

public protocol StorageManagerProtocol: AnyObject {
    var freeDiskSpaceBytes: Int64 { get }
    var totalDiskSpaceBytes: Int64 { get }
    var appDownloadsUsageBytes: Int64 { get }
    var formattedFreeDiskSpace: String { get }
    var formattedTotalDiskSpace: String { get }
    var formattedAppDownloadsUsage: String { get }
    var storageUsedPercentage: Double { get }
    
    func isDiskSpaceSufficient(for expectedBytes: Int64) -> Bool
    func invalidateCache()
}

public final class StorageManager: StorageManagerProtocol {
    private let fileManager = FileManager.default
    private let fileManagementService: FileManagementServiceProtocol
    
    private var cachedFreeDiskSpace: Int64 = 0
    private var cachedTotalDiskSpace: Int64 = 0
    private var cachedAppDownloadsUsage: Int64 = 0
    private var lastCacheTime: Date = .distantPast
    private let cacheTTL: TimeInterval = 10.0 // Cache disk stat results for 10 seconds
    
    public init(fileManagementService: FileManagementServiceProtocol = ServiceContainer.shared.fileManagementService) {
        self.fileManagementService = fileManagementService
    }
    
    public func invalidateCache() {
        lastCacheTime = .distantPast
    }
    
    private func updateCacheIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCacheTime) > cacheTTL else { return }
        
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        
        // 1. Total & Free disk space
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: documentsURL.path) {
            if let freeSize = attributes[.systemFreeSize] as? NSNumber {
                cachedFreeDiskSpace = freeSize.int64Value
            }
            if let totalSize = attributes[.systemSize] as? NSNumber {
                cachedTotalDiskSpace = totalSize.int64Value
            }
        }
        
        // 2. App downloads folder usage
        let folderURL = fileManagementService.downloadsDirectoryURL
        if let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize {
                    total += Int64(size)
                }
            }
            cachedAppDownloadsUsage = total
        }
        
        lastCacheTime = now
    }
    
    public var freeDiskSpaceBytes: Int64 {
        updateCacheIfNeeded()
        return cachedFreeDiskSpace
    }
    
    public var totalDiskSpaceBytes: Int64 {
        updateCacheIfNeeded()
        return cachedTotalDiskSpace
    }
    
    public var appDownloadsUsageBytes: Int64 {
        updateCacheIfNeeded()
        return cachedAppDownloadsUsage
    }
    
    public var formattedFreeDiskSpace: String {
        ByteCountFormatter.string(fromByteCount: freeDiskSpaceBytes, countStyle: .file)
    }
    
    public var formattedTotalDiskSpace: String {
        ByteCountFormatter.string(fromByteCount: totalDiskSpaceBytes, countStyle: .file)
    }
    
    public var formattedAppDownloadsUsage: String {
        ByteCountFormatter.string(fromByteCount: appDownloadsUsageBytes, countStyle: .file)
    }
    
    public var storageUsedPercentage: Double {
        let total = totalDiskSpaceBytes
        guard total > 0 else { return 0.0 }
        let used = total - freeDiskSpaceBytes
        return min(max(Double(used) / Double(total), 0.0), 1.0)
    }
    
    public func isDiskSpaceSufficient(for expectedBytes: Int64) -> Bool {
        guard expectedBytes > 0 else { return true }
        let requiredBuffer: Int64 = 100 * 1024 * 1024
        return freeDiskSpaceBytes >= (expectedBytes + requiredBuffer)
    }
}
