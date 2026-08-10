import SwiftUI
import WebKit

public struct BrowserSettingsSheet: View {
    @ObservedObject var settings = BrowserSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showClearedAlert = false
    @State private var clearedMessage = ""
    
    public var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    HStack {
                        Text("Homepage")
                        Spacer()
                        TextField("Homepage URL", text: $settings.homepage)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    }
                    
                    Picker("Default Search Engine", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    
                    Toggle("Request Desktop Website by Default", isOn: $settings.requestDesktopByDefault)
                    Toggle("Restore Tabs on Launch", isOn: $settings.restoreTabsOnLaunch)
                }
                
                Section("Privacy & Protection") {
                    Toggle("Ad Blocker (WKContentRuleList)", isOn: $settings.isAdBlockerEnabled)
                    Toggle("JavaScript", isOn: $settings.isJavaScriptEnabled)
                    Toggle("Block Pop-ups", isOn: $settings.isPopupBlockingEnabled)
                }
                
                Section("Website Data & Storage") {
                    Button("Clear History") {
                        BrowserHistoryManager.shared.clearAllHistory()
                        showNotification("History cleared.")
                    }
                    Button("Clear Cache & Website Data", role: .destructive) {
                        WKWebsiteDataStore.default().removeData(
                            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                            modifiedSince: Date.distantPast
                        ) {
                            showNotification("Cache & cookies cleared.")
                        }
                    }
                }
                
                Section("Future Features (Placeholders)") {
                    Label("Reader Mode", systemImage: "doc.plaintext")
                        .foregroundStyle(.secondary)
                    Label("Translate Page", systemImage: "translate")
                        .foregroundStyle(.secondary)
                    Label("AI Summary", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                    Label("Password Manager", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                    Label("Extensions", systemImage: "puzzlepiece.fill")
                        .foregroundStyle(.secondary)
                    Label("Cloud Sync", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Browser Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Success", isPresented: $showClearedAlert) {
                Button("OK") {}
            } message: {
                Text(clearedMessage)
            }
        }
    }
    
    private func showNotification(_ message: String) {
        clearedMessage = message
        showClearedAlert = true
    }
}
