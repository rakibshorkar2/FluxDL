import SwiftUI

public struct QueueSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var queueManager: QueueManager = (ServiceContainer.shared.queueManager as? QueueManager) ?? QueueManager()
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Execution Mode"), footer: Text("Parallel mode downloads up to the concurrent limit at once. Sequential mode processes one download at a time in order.")) {
                    Picker("Queue Mode", selection: $queueManager.queueMode) {
                        ForEach(QueueMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if queueManager.queueMode == .parallel {
                        Stepper("Max Concurrent: \(queueManager.maxConcurrentDownloads)", value: $queueManager.maxConcurrentDownloads, in: 1...10)
                    }
                }
                
                Section(header: Text("Automation & Safety")) {
                    Toggle("Auto-Retry Failed Downloads", isOn: $queueManager.autoRetryEnabled)
                    Toggle("Warn on Duplicate Links", isOn: $queueManager.duplicateDetectionEnabled)
                }
            }
            .navigationTitle("Queue Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
