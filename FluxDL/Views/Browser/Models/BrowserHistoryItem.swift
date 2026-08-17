import Foundation

public struct BrowserHistoryItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var urlString: String
    public let visitDate: Date
    
    public init(id: UUID = UUID(), title: String, urlString: String, visitDate: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.visitDate = visitDate
    }
}
