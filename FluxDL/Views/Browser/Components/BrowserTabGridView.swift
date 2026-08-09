import SwiftUI

public struct BrowserTabGridView: View {
    @ObservedObject var tabManager: BrowserTabManager = BrowserTabManager.shared
    @Environment(\.dismiss) private var dismiss
    
    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(tabManager.tabs) { tab in
                            let isSelected = tab.id == tabManager.activeTabId
                            
                            GlassCard(padding: 10) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: tab.isPrivate ? "eye.slash.fill" : "globe")
                                            .font(.caption)
                                            .foregroundStyle(tab.isPrivate ? Color.purple : Color.accentColor)
                                        
                                        Text(tab.title)
                                            .font(.caption.bold())
                                            .lineLimit(1)
                                        
                                        Spacer()
                                        
                                        Button(action: { tabManager.closeTab(id: tab.id) }) {
                                            Image(systemName: "xmark")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.secondary)
                                                .padding(4)
                                                .background(Color.primary.opacity(0.1), in: Circle())
                                        }
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
                            .onTapGesture {
                                tabManager.selectTab(id: tab.id)
                                dismiss()
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
            .navigationTitle("Tabs (\(tabManager.tabs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !tabManager.recentlyClosedTabs.isEmpty {
                        Button(action: { tabManager.restoreLastClosedTab() }) {
                            Label("Restore Tab", systemImage: "arrow.uturn.backward.circle")
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
        }
    }
}
