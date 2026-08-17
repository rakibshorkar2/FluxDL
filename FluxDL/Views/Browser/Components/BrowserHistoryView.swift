import SwiftUI

public struct BrowserHistoryView: View {
    @ObservedObject var historyManager = BrowserHistoryManager.shared
    let onOpenURL: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    
    public var filteredHistory: [BrowserHistoryItem] {
        if searchText.isEmpty {
            return historyManager.historyItems
        }
        return historyManager.historyItems.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.urlString.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    public var body: some View {
        NavigationStack {
            Group {
                if filteredHistory.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "clock")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No Browsing History")
                            .font(.headline)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(filteredHistory) { item in
                            HStack(spacing: 12) {
                                BrowserFaviconView(url: URL(string: item.urlString), fallbackText: item.title, size: 20)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    Text(item.urlString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(item.visitDate.formatted(date: .numeric, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
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
                                Button(role: .destructive, action: { historyManager.deleteEntry(id: item.id) }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                historyManager.deleteEntry(id: filteredHistory[index].id)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, prompt: "Search history...")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !historyManager.historyItems.isEmpty {
                        Button("Clear All", role: .destructive) {
                            historyManager.clearAllHistory()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
