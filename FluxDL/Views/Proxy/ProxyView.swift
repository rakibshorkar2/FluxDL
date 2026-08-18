import SwiftUI
import UniformTypeIdentifiers

// MARK: - ProxyView
//
// The Proxy tab. Replaces the former History tab.

public struct ProxyView: View {
    @StateObject private var viewModel = ProxyViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                List {
                    Section {
                        ProxyStatusCard(service: viewModel.service) {
                            viewModel.toggleEnabled()
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        if viewModel.service.profiles.isEmpty {
                            emptyState
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(viewModel.service.profiles) { profile in
                                ProxyProfileRow(
                                    profile: profile,
                                    isSelected: profile.id == viewModel.service.selectedProfileID,
                                    onSelect: { viewModel.selectProfile(profile) },
                                    onEdit: {
                                        viewModel.editingProfile = profile
                                        viewModel.isAddSheetPresented = true
                                    },
                                    onTest: { viewModel.testProfile(profile) },
                                    onDelete: { viewModel.confirmDelete(profile) }
                                )
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    } header: {
                        if !viewModel.service.profiles.isEmpty {
                            HStack {
                                Text("Saved Proxies")
                                Spacer()
                                Text("\(viewModel.service.profiles.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Proxy")
            .toolbar { toolbarContent }
            .animation(.easeInOut(duration: 0.25), value: viewModel.service.profiles.map(\.id))

            // ── Sheets & import ────────────────────────────────────────────
            .sheet(isPresented: $viewModel.isAddSheetPresented) {
                AddEditProxySheet(viewModel: viewModel, profile: viewModel.editingProfile)
            }
            // UIKit document picker requesting a copy (asCopy: true) instead of
            // SwiftUI's .fileImporter: the picked document must be an app-local
            // copy so importing works under virtualized environments
            // (LiveContainer) where security-scoped provider URLs can be
            // unreliable. .data is allowed as a fallback because some document
            // providers misreport YAML files; the content is validated before
            // parsing.
            .sheet(isPresented: $viewModel.isYAMLImportPresented) {
                DocumentFilePickerView(
                    contentTypes: [.yaml, .plainText, .text, .data],
                    onPicked: { url in
                        viewModel.isYAMLImportPresented = false
                        handleYAMLPicked(url)
                    },
                    onCancel: { viewModel.isYAMLImportPresented = false }
                )
            }
            .sheet(isPresented: $viewModel.isYAMLResultsPresented) {
                if let importResult = viewModel.yamlImportResult {
                    ProxyYAMLImportView(viewModel: viewModel, result: importResult)
                }
            }
            .alert(
                "Proxy",
                isPresented: $viewModel.isAlertPresented,
                presenting: viewModel.alertMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .confirmationDialog(
                "Delete Proxy?",
                isPresented: $viewModel.isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                if let profile = viewModel.profilePendingDelete {
                    Button("Delete \u{201C}\(profile.configuration.name)\u{201D}", role: .destructive) {
                        viewModel.deleteProfile(profile)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This proxy profile will be removed permanently.")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                viewModel.isYAMLImportPresented = true
            } label: {
                Label("Import YAML", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("proxy.importYAMLButton")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                viewModel.editingProfile = nil
                viewModel.isAddSheetPresented = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityIdentifier("proxy.addButton")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color.blue)
                }
                .accessibilityHidden(true)

                Text("No Proxy Configured")
                    .font(.headline)

                Text("Add a SOCKS5 proxy manually or import one from a YAML file. When enabled, FluxDL routes app downloads and browser traffic through it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    Button {
                        viewModel.editingProfile = nil
                        viewModel.isAddSheetPresented = true
                    } label: {
                        Label("Add Proxy", systemImage: "plus")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("proxy.empty.addButton")

                    Button {
                        viewModel.isYAMLImportPresented = true
                    } label: {
                        Label("Import YAML", systemImage: "doc.badge.plus")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("proxy.empty.importButton")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - YAML import

    /// Handles a document picked through `DocumentFilePickerView`. The URL is
    /// a system-provided copy (asCopy: true); a defensive local copy is still
    /// taken when the URL is not app-local. The existing parser stays the
    /// authority for whether the content actually is YAML.
    private func handleYAMLPicked(_ url: URL) {
        switch ImportedDocumentReader.readableCopy(of: url, preferredExtension: "yaml") {
        case .failure(let error):
            viewModel.showError(error.userMessage)
        case .success(let localURL):
            defer { ImportedDocumentReader.removeTemporaryCopy(at: localURL) }
            switch ImportedDocumentReader.readText(from: localURL) {
            case .failure(let error):
                viewModel.showError(error.userMessage)
            case .success(let text):
                if ImportedDocumentReader.isYAMLDocument(url) {
                    viewModel.importYAML(text)
                } else if viewModel.service.parseYAML(text) != nil {
                    viewModel.importYAML(text)
                } else {
                    viewModel.showError("The selected file is not a valid FluxDL proxy YAML file.")
                }
            }
        }
    }
}
