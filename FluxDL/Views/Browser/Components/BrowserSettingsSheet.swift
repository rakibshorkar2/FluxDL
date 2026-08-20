import SwiftUI
import WebKit

public struct BrowserSettingsSheet: View {
    @ObservedObject var settings = BrowserSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showClearedAlert = false
    @State private var clearedMessage = ""
    @State private var newRule = ""
    @State private var showRuleError = false
    
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
                
                Section {
                    Picker("Webpage Appearance", selection: $settings.webpageAppearance) {
                        ForEach(WebpageAppearance.allCases) { appearance in
                            Text(appearance.rawValue).tag(appearance)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Webpage Appearance")
                } footer: {
                    Text("System follows the OS appearance. Dark/Light request that rendering for every page. Automatic lets each website use its own native dark theme without forced styling.")
                }
                
                Section("Privacy & Protection") {
                    Toggle("Ad Blocker", isOn: $settings.isAdBlockerEnabled)
                    Toggle("JavaScript", isOn: $settings.isJavaScriptEnabled)
                    Toggle("Block Pop-ups", isOn: $settings.isPopupBlockingEnabled)
                }
                
                Section {
                    HStack {
                        TextField("Pattern, e.g. ads.example.com", text: $newRule)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add") { addCustomRule() }
                            .disabled(newRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    
                    if settings.customBlockRules.isEmpty {
                        Text("No custom rules. Add patterns to block, e.g. `doubleclick.net` or `*tracker*.js`. `*` is a wildcard.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.customBlockRules, id: \.self) { rule in
                            HStack {
                                Image(systemName: "nosign")
                                    .foregroundStyle(Color.red)
                                Text(rule)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                                Spacer()
                                Button(role: .destructive) {
                                    removeCustomRule(rule)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Custom Block Rules")
                } footer: {
                    Text("These act like ad-blocking extensions: matching requests are blocked on every site. Changes apply to newly opened pages.")
                }
                
                if !settings.adBlockWhitelist.isEmpty {
                    Section("Allowed Sites (ad blocking off)") {
                        ForEach(settings.adBlockWhitelist, id: \.self) { domain in
                            HStack {
                                Image(systemName: "checkmark.shield")
                                    .foregroundStyle(Color.green)
                                Text(domain)
                                    .font(.subheadline)
                                Spacer()
                                Button(role: .destructive) {
                                    settings.toggleWhitelist(domain: domain)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
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
                    Label("Translate Page", systemImage: "translate")
                        .foregroundStyle(.secondary)
                    Label("AI Summary", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                    Label("Password Manager", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                    Label("Cloud Sync", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(AppToggleStyle())
            .navigationTitle("Browser Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Invalid Rule", isPresented: $showRuleError) {
                Button("OK") {}
            } message: {
                Text("Enter a URL pattern like `ads.example.com` or `*tracker*.js`.")
            }
            .alert("Success", isPresented: $showClearedAlert) {
                Button("OK") {}
            } message: {
                Text(clearedMessage)
            }
        }
    }
    
    private func addCustomRule() {
        let rule = newRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty, !rule.contains(" ") else {
            showRuleError = true
            return
        }
        guard !settings.customBlockRules.contains(rule) else { return }
        settings.customBlockRules.append(rule)
        newRule = ""
        AdBlockEngine.shared.reloadCustomRules()
        showNotification("Rule added: \(rule)")
    }
    
    private func removeCustomRule(_ rule: String) {
        settings.customBlockRules.removeAll { $0 == rule }
        AdBlockEngine.shared.reloadCustomRules()
    }
    
    private func showNotification(_ message: String) {
        clearedMessage = message
        showClearedAlert = true
    }
}
