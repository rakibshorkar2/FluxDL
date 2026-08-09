import SwiftUI

public struct BrowserBookmarksView: View {
    @ObservedObject var bookmarkManager = BookmarkManager.shared
    let onOpenURL: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    @State private var selectedFolder = "All"
    @State private var isAddFolderAlertPresented = false
    @State private var newFolderName = ""
    
    public var filteredBookmarks: [BookmarkItem] {
        bookmarkManager.bookmarks.filter { item in
            let matchesSearch = searchText.isEmpty ||
                item.title.localizedCaseInsensitiveContains(searchText) ||
                item.urlString.localizedCaseInsensitiveContains(searchText)
            let matchesFolder = selectedFolder == "All" || item.folder == selectedFolder
            return matchesSearch && matchesFolder
        }
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Folder filter pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FolderChip(title: "All", isSelected: selectedFolder == "All") {
                            selectedFolder = "All"
                        }
                        ForEach(bookmarkManager.folders, id: \.self) { folder in
                            FolderChip(title: folder, isSelected: selectedFolder == folder) {
                                selectedFolder = folder
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                
                if filteredBookmarks.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bookmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No Bookmarks Found")
                            .font(.headline)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(filteredBookmarks) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.isFavorite ? "star.fill" : "bookmark.fill")
                                    .foregroundStyle(item.isFavorite ? Color.orange : Color.accentColor)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    Text(item.urlString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let url = URL(string: item.urlString) {
                                    onOpenURL(url)
                                    dismiss()
                                }
                            }
                            .contextMenu {
                                Button(action: {
                                    if let url = URL(string: item.urlString) {
                                        _ = BrowserTabManager.shared.createNewTab(url: url)
                                        dismiss()
                                    }
                                }) {
                                    Label("Open in New Tab", systemImage: "plus.square")
                                }
                                Button(action: { bookmarkManager.toggleFavorite(id: item.id) }) {
                                    Label(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
                                }
                                Button(role: .destructive, action: { bookmarkManager.removeBookmark(id: item.id) }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                bookmarkManager.removeBookmark(id: filteredBookmarks[index].id)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, prompt: "Search bookmarks...")
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Add Folder") { isAddFolderAlertPresented = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New Folder", isPresented: $isAddFolderAlertPresented) {
                TextField("Folder Name", text: $newFolderName)
                Button("Add") {
                    bookmarkManager.addFolder(newFolderName)
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct FolderChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
    }
}
