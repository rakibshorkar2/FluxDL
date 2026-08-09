import SwiftUI

public struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @State private var taskToDelete: DownloadTaskModel?
    @State private var showDeleteConfirm = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                if viewModel.completedTasks.isEmpty {
                    VStack(spacing: 20) {
                        GlassCard(padding: 28) {
                            VStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Color.orange.opacity(0.12))
                                        .frame(width: 70, height: 70)
                                    
                                    Image(systemName: "clock.fill")
                                        .font(.system(size: 36, weight: .medium))
                                        .foregroundStyle(Color.orange)
                                }
                                
                                Text("No Download History")
                                    .font(.headline)
                                
                                Text("Completed downloads and saved files history log will be tracked here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                
                                StatusBadge(title: "Queue Clear", icon: "checkmark.circle.fill", color: .green)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.completedTasks) { task in
                                GlassCard(padding: 14) {
                                    HStack(spacing: 12) {
                                        Image(systemName: iconForFilename(task.filename))
                                            .font(.title2)
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 36, height: 36)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(task.filename)
                                                .font(.subheadline.bold())
                                                .lineLimit(1)
                                            
                                            HStack(spacing: 8) {
                                                Text(task.formattedTotalSize)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                
                                                if let completedAt = task.completedAt {
                                                    Text("• \(completedAt.formatted(date: .numeric, time: .shortened))")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            taskToDelete = task
                                            showDeleteConfirm = true
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !viewModel.completedTasks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear All") {
                            viewModel.clearAllHistory()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete History Record?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove from History Only") {
                    if let task = taskToDelete {
                        viewModel.deleteHistoryItem(task, deleteFile: false)
                    }
                }
                Button("Delete File & Record", role: .destructive) {
                    if let task = taskToDelete {
                        viewModel.deleteHistoryItem(task, deleteFile: true)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    
    private func iconForFilename(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "mp4", "mkv", "mov", "avi": return "video.fill"
        case "mp3", "m4a", "flac", "wav": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "gif": return "photo.fill"
        case "ipa", "apk": return "app.fill"
        default: return "doc.fill"
        }
    }
}
