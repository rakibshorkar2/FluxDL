import SwiftUI

// MARK: - Flux Assistant sheet (Downloads tab)

/// Deterministic local assistant: typed commands map to existing engine APIs
/// (pause all, resume all, retry failed, filters, size thresholds, names).
/// No network, no AI service — answers are computed from the task list.
public struct DownloadAssistantSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    @State private var result: DownloadAssistantResult?
    @State private var isRunning = false

    private let engine: DownloadEngineProtocol = ServiceContainer.shared.downloadEngine

    private static let suggestions: [String] = [
        "pause all",
        "resume all",
        "retry failed",
        "show failed",
        "show completed",
        "downloads larger than 5 GB",
        "show .zip downloads",
        "pause <name>"
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Suggestions
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            Button {
                                input = suggestion
                                run()
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Divider()

                List {
                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .listRowSeparator(.hidden)
                    } else if let result {
                        Section {
                            Label(result.summary, systemImage: result.icon)
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.accentColor)
                                .listRowSeparator(.hidden)
                        }
                        if !result.items.isEmpty {
                            Section("Results") {
                                ForEach(result.items, id: \.self) { item in
                                    Text(item)
                                        .font(.subheadline)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "Ask about your downloads",
                            systemImage: "sparkles",
                            description: Text("Try “pause all”, “show failed”, or “downloads larger than 5 GB”.")
                        )
                    }
                }
                .listStyle(.insetGrouped)

                // Input bar
                HStack(spacing: 10) {
                    TextField("Type a command…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { run() }
                    Button(action: run) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("Flux Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(false)
    }

    private func run() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isRunning else { return }
        isRunning = true
        let command = DownloadAssistantParser.parse(raw)
        Task { @MainActor in
            result = await DownloadAssistantExecutor.execute(command, engine: engine)
            isRunning = false
        }
    }
}