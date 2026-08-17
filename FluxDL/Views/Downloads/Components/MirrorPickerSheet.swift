import SwiftUI

// MARK: - MirrorPickerSheet

public struct MirrorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let task: DownloadTaskModel

    @State private var newMirrorString: String = ""
    @State private var addError: String?
    @State private var showAddField: Bool = false

    private var engine: DownloadEngine? {
        ServiceContainer.shared.downloadEngine as? DownloadEngine
    }

    // Live task to reflect updates
    @ObservedObject private var liveEngine: DownloadEngine
    private var liveTask: DownloadTaskModel {
        liveEngine.tasks.first { $0.id == task.id } ?? task
    }

    public init(task: DownloadTaskModel) {
        self.task = task
        self.liveEngine = ServiceContainer.shared.downloadEngine as! DownloadEngine
    }

    public var body: some View {
        NavigationStack {
            List {
                // ── Primary URL ──────────────────────────────────────────
                Section("Primary URL") {
                    MirrorRow(
                        index: 0,
                        url: liveTask.url,
                        isActive: liveTask.currentMirrorIndex == 0,
                        canDelete: false,
                        onSelect: { switchToMirror(0) },
                        onDelete: { }
                    )
                }

                // ── Mirrors ──────────────────────────────────────────────
                if !liveTask.mirrors.isEmpty {
                    Section("Mirrors") {
                        ForEach(Array(liveTask.mirrors.enumerated()), id: \.offset) { i, url in
                            MirrorRow(
                                index: i + 1,
                                url: url,
                                isActive: liveTask.currentMirrorIndex == i + 1,
                                canDelete: true,
                                onSelect: { switchToMirror(i + 1) },
                                onDelete: { removeMirror(at: i) }
                            )
                        }
                    }
                }

                // ── Add Mirror ───────────────────────────────────────────
                Section {
                    if showAddField {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("https://mirror.example.com/file.zip", text: $newMirrorString)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            if let error = addError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            HStack {
                                Button("Cancel") {
                                    showAddField = false
                                    newMirrorString = ""
                                    addError = nil
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button("Add") {
                                    addMirror()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(newMirrorString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            showAddField = true
                        } label: {
                            Label("Add Mirror URL", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Add Mirror")
                } footer: {
                    Text("Mirrors are tried automatically after \(DownloadMirrorManager.shared.autoSwitchThreshold) consecutive failures on the active URL.")
                        .font(.caption)
                }

                // ── Info ─────────────────────────────────────────────────
                if liveTask.mirrorSwitchCount > 0 {
                    Section("History") {
                        LabeledContent("Auto-switches", value: "\(liveTask.mirrorSwitchCount)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Mirror URLs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Logic

    private func switchToMirror(_ index: Int) {
        guard let engine else { return }
        DownloadMirrorManager.shared.selectMirror(index: index, for: liveTask.id, engine: engine)
    }

    private func addMirror() {
        var clean = newMirrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.lowercased().hasPrefix("http://") && !clean.lowercased().hasPrefix("https://") {
            clean = "https://" + clean
        }
        guard let url = URL(string: clean), UIApplication.shared.canOpenURL(url) else {
            addError = "Please enter a valid HTTP or HTTPS URL."
            return
        }
        guard let engine else { return }
        DownloadMirrorManager.shared.addMirror(url, to: liveTask.id, engine: engine)
        newMirrorString = ""
        addError = nil
        showAddField = false
    }

    private func removeMirror(at index: Int) {
        guard let engine else { return }
        DownloadMirrorManager.shared.removeMirror(at: index, from: liveTask.id, engine: engine)
    }
}

// MARK: - MirrorRow

private struct MirrorRow: View {
    let index:     Int
    let url:       URL
    let isActive:  Bool
    let canDelete: Bool
    let onSelect:  () -> Void
    let onDelete:  () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Active indicator
            ZStack {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(index == 0 ? "Primary" : "Mirror \(index)")
                    .font(.caption.bold())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if !isActive {
                Button("Switch") { onSelect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.accentColor)
            }

            if canDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
