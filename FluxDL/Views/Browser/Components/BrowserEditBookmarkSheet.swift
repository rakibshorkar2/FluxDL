import SwiftUI

/// Sheet for editing an existing bookmark's title, folder and favorite state.
public struct BrowserEditBookmarkSheet: View {
    @ObservedObject var bookmarkManager = BookmarkManager.shared
    @Environment(\.dismiss) private var dismiss
    
    let item: BookmarkItem
    
    @State private var title: String = ""
    @State private var folder: String = "Bookmarks"
    @State private var isFavorite: Bool = false
    @State private var isNewFolderAlertPresented = false
    @State private var newFolderName = ""
    
    public init(item: BookmarkItem) {
        self.item = item
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("URL", text: .constant(item.urlString))
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
                
                Section("Folder") {
                    Picker("Folder", selection: $folder) {
                        ForEach(bookmarkManager.folders, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Button("Add New Folder...") {
                        isNewFolderAlertPresented = true
                    }
                }
                
                Section {
                    Toggle("Favorite", isOn: $isFavorite)
                }
            }
            .toggleStyle(AppToggleStyle())
            .navigationTitle("Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        bookmarkManager.updateBookmark(
                            id: item.id,
                            newTitle: title,
                            newFolder: folder,
                            isFavorite: isFavorite
                        )
                        dismiss()
                    }
                }
            }
            .alert("New Folder", isPresented: $isNewFolderAlertPresented) {
                TextField("Folder Name", text: $newFolderName)
                Button("Add") {
                    bookmarkManager.addFolder(newFolderName)
                    folder = newFolderName
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                title = item.title
                folder = item.folder
                isFavorite = item.isFavorite
            }
        }
    }
}
