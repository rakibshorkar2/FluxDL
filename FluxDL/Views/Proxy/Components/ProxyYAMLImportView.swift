import SwiftUI

// MARK: - ProxyYAMLImportView
//
// Shows the outcome of parsing a YAML file: valid proxies (selectable for
// import) and per-entry parsing errors.

public struct ProxyYAMLImportView: View {
    @ObservedObject public var viewModel: ProxyViewModel
    public let result: ProxyYAMLImportResult

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []

    private let haptics = ServiceContainer.shared.hapticService

    public init(viewModel: ProxyViewModel, result: ProxyYAMLImportResult) {
        self.viewModel = viewModel
        self.result = result
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                        Text(summaryText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if !result.configurations.isEmpty {
                    Section {
                        ForEach(result.configurations) { configuration in
                            configurationRow(configuration)
                        }
                    } header: {
                        HStack {
                            Text("Valid Proxies (\(result.configurations.count))")
                            Spacer()
                            Button(allSelected ? "Deselect All" : "Select All") {
                                toggleSelectAll()
                            }
                            .font(.caption.bold())
                        }
                    }
                }

                if !result.errors.isEmpty {
                    Section {
                        ForEach(result.errors) { error in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    if let name = error.displayName {
                                        Text(name)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text(error.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Skipped (\(result.errors.count))")
                    }
                }
            }
            .navigationTitle("Import YAML")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                importBar
            }
            .onAppear {
                selectedIDs = Set(result.configurations.map { $0.id })
            }
        }
    }

    // MARK: - Rows

    private func configurationRow(_ configuration: ProxyConfiguration) -> some View {
        Button {
            if selectedIDs.contains(configuration.id) {
                selectedIDs.remove(configuration.id)
            } else {
                selectedIDs.insert(configuration.id)
            }
            haptics.selectionChanged()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedIDs.contains(configuration.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(configuration.id) ? Color.accentColor : Color.secondary.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(configuration.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        Text(configuration.type.displayName)
                        Text("\u{2022}")
                        Text(configuration.hostAndPortString)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .accessibilityIdentifier("proxy.yaml.row.\(configuration.name)")
    }

    // MARK: - Import bar

    private var importBar: some View {
        Button {
            let configurations = result.configurations.filter { selectedIDs.contains($0.id) }
            viewModel.importConfigurations(configurations)
            dismiss()
        } label: {
            Text(importButtonTitle)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    selectedIDs.isEmpty
                        ? Color.gray.opacity(0.3)
                        : Color.accentColor,
                    in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(selectedIDs.isEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier("proxy.yaml.import")
    }

    // MARK: - Helpers

    private var allSelected: Bool {
        !result.configurations.isEmpty && selectedIDs.count == result.configurations.count
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedIDs = []
        } else {
            selectedIDs = Set(result.configurations.map { $0.id })
        }
        haptics.selectionChanged()
    }

    private var summaryText: String {
        let valid = result.validCount
        let failed = result.errorCount
        if valid > 0 && failed > 0 {
            return "\(valid) proxy found and \(failed) skipped. Select the proxies to import."
        }
        if valid > 0 {
            return "\(valid) proxy found. Select the proxies to import."
        }
        return "No valid proxies were found. See the skipped entries below."
    }

    private var importButtonTitle: String {
        selectedIDs.isEmpty ? "Select a Proxy" : "Import (\(selectedIDs.count))"
    }
}
