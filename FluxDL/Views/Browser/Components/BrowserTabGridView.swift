import SwiftUI

public struct BrowserTabGridView: View {
    @ObservedObject var tabManager: BrowserTabManager = BrowserTabManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isCloseAllAlertPresented = false
    
    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                if tabManager.tabs.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "square.on.square.dashed")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("No Tabs Open")
                            .font(.headline)
                        Button("New Tab") {
                            _ = tabManager.createNewTab()
                            dismiss()
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(tabManager.tabs) { tab in
                                let isSelected = tab.id == tabManager.activeTabId
                                
                                BrowserTabCard(
                                    tab: tab,
                                    isSelected: isSelected,
                                    onSelect: {
                                        tabManager.selectTab(id: tab.id)
                                        dismiss()
                                    },
                                    onClose: { tabManager.closeTab(id: tab.id) }
                                )
                                .draggable(tab.id.uuidString) {
                                    BrowserTabCard(
                                        tab: tab,
                                        isSelected: isSelected,
                                        onSelect: {},
                                        onClose: {}
                                    )
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let first = items.first,
                                          let draggedID = UUID(uuidString: first),
                                          let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedID }),
                                          let toIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
                                          fromIndex != toIndex else { return false }
                                    withAnimation(.snappy) {
                                        tabManager.moveTab(from: IndexSet(integer: fromIndex), to: toIndex)
                                    }
                                    return true
                                }
                                .contextMenu {
                                    Button(action: { tabManager.duplicateTab(id: tab.id) }) {
                                        Label("Duplicate Tab", systemImage: "plus.square.on.square")
                                    }
                                    Button(role: .destructive, action: { tabManager.closeTab(id: tab.id) }) {
                                        Label("Close Tab", systemImage: "xmark.circle")
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Tabs (\(tabManager.tabs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 16) {
                        if !tabManager.recentlyClosedTabs.isEmpty {
                            Button(action: { tabManager.restoreLastClosedTab() }) {
                                Label("Restore Tab", systemImage: "arrow.uturn.backward.circle")
                            }
                        }
                        if !tabManager.tabs.isEmpty {
                            Button(role: .destructive, action: { isCloseAllAlertPresented = true }) {
                                Label("Close All", systemImage: "trash")
                            }
                        }
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        _ = tabManager.createNewTab()
                        dismiss()
                    }) {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                }
            }
            .alert("Close All Tabs?", isPresented: $isCloseAllAlertPresented) {
                Button("Close All", role: .destructive) { tabManager.closeAllTabs() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will close all \(tabManager.tabs.count) open tabs.")
            }
        }
    }
}

private struct BrowserTabCard: View {
    let tab: BrowserTabModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    
    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    BrowserFaviconView(
                        url: tab.faviconURL ?? tab.url,
                        fallbackText: tab.title,
                        size: 16
                    )
                    
                    Text(tab.title)
                        .font(.caption.bold())
                        .lineLimit(1)
                    
                    Spacer(minLength: 0)
                    
                    if tab.isPrivate {
                        Image(systemName: "eye.slash.fill")
                            .font(.caption)
                            .foregroundStyle(Color.purple)
                    }
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .background(Color.primary.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                
                // Thumbnail preview card
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(height: 120)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "globe")
                                .font(.title2)
                                .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                            Text(tab.url?.host ?? "New Tab")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
