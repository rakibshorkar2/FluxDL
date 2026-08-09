import Foundation

public struct BookmarkItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var urlString: String
    public var folder: String
    public var isFavorite: Bool
    public let createdAt: Date
    
    public init(
        id: UUID = UUID(),
        title: String,
        urlString: String,
        folder: String = "Bookmarks",
        isFavorite: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.folder = folder
        self.isFavorite = isFavorite
        self.createdAt = createdAt
    }
}
