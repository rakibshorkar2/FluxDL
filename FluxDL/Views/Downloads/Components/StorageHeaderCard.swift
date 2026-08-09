import SwiftUI

public struct StorageHeaderCard: View {
    public let freeDiskSpace: String
    public let appUsage: String
    public let usedPercentage: Double
    public let activeQueueMode: String
    public let maxConcurrent: Int
    
    public init(
        freeDiskSpace: String,
        appUsage: String,
        usedPercentage: Double,
        activeQueueMode: String,
        maxConcurrent: Int
    ) {
        self.freeDiskSpace = freeDiskSpace
        self.appUsage = appUsage
        self.usedPercentage = usedPercentage
        self.activeQueueMode = activeQueueMode
        self.maxConcurrent = maxConcurrent
    }
    
    public var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Device Storage", systemImage: "internaldrive.fill")
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    
                    Spacer()
                    
                    StatusBadge(
                        title: "\(activeQueueMode) • Max \(maxConcurrent)",
                        icon: activeQueueMode == "Parallel" ? "line.3.horizontal.decrease.circle.fill" : "arrow.down.right.and.arrow.up.left",
                        color: .blue
                    )
                }
                
                VStack(spacing: 6) {
                    ProgressView(value: usedPercentage)
                        .tint(usedPercentage > 0.9 ? Color.red : Color.blue)
                    
                    HStack {
                        Text("Free: \(freeDiskSpace)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Text("FluxDL Saved: \(appUsage)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
}
