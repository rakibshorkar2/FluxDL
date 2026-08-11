import Foundation
import Combine

@MainActor
public final class BookmarkManager: ObservableObject {
    public static let shared = BookmarkManager()
    
    @Published public private(set) var bookmarks: [BookmarkItem] = []
    @Published public private(set) var folders: [String] = ["Bookmarks", "Favorites", "Work", "Personal"]
    
    private let storageKey = "fluxdl_browser_bookmarks"
    private let foldersKey = "fluxdl_browser_folders"
    
    private init() {
        loadBookmarks()
        loadFolders()
        if bookmarks.isEmpty {
            addDefaultBookmarks()
        }
    }
    
    public func addBookmark(title: String, urlString: String, folder: String = "Bookmarks", isFavorite: Bool = false) {
        let item = BookmarkItem(title: title.isEmpty ? urlString : title, urlString: urlString, folder: folder, isFavorite: isFavorite)
        bookmarks.insert(item, at: 0)
        saveBookmarks()
    }
    
    public func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }
    
    public func updateBookmark(id: UUID, newTitle: String, newFolder: String, isFavorite: Bool) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].title = newTitle
        bookmarks[idx].folder = newFolder
        bookmarks[idx].isFavorite = isFavorite
        saveBookmarks()
    }
    
    public func isBookmarked(urlString: String) -> Bool {
        bookmarks.contains { $0.urlString == urlString }
    }
    
    public func toggleFavorite(id: UUID) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].isFavorite.toggle()
        saveBookmarks()
    }
    
    public func addFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        saveFolders()
    }
    
    public func removeFolder(_ name: String) {
        guard folders.contains(name), name != "Bookmarks" else { return }
        folders.removeAll { $0 == name }
        // Bookmark items pointing at the deleted folder fall back to the root.
        for idx in bookmarks.indices where bookmarks[idx].folder == name {
            bookmarks[idx].folder = "Bookmarks"
        }
        saveBookmarks()
        saveFolders()
    }
    
    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: foldersKey)
        }
    }
    
    private func loadFolders() {
        if let data = UserDefaults.standard.data(forKey: foldersKey),
           let stored = try? JSONDecoder().decode([String].self, from: data),
           !stored.isEmpty {
            self.folders = Array(Set(stored)).sorted()
        } else {
            // Persist the defaults once so user-created folders layer on top.
            saveFolders()
        }
    }
    
    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let items = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            self.bookmarks = items
        }
    }
    
    private func addDefaultBookmarks() {
        addBookmark(title: "Google", urlString: "https://google.com", folder: "Favorites", isFavorite: true)
        addBookmark(title: "GitHub", urlString: "https://github.com", folder: "Favorites", isFavorite: true)
        addBookmark(title: "Archive.org", urlString: "https://archive.org", folder: "Bookmarks", isFavorite: false)
        addBookmark(title: "Apple", urlString: "https://apple.com", folder: "Favorites", isFavorite: true)
    }
}
