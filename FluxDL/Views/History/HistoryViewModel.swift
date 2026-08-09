import Foundation
import Combine

@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public private(set) var completedTasks: [DownloadTaskModel] = []
    
    private let engine: DownloadEngineProtocol
    private let hapticService: HapticServiceProtocol
    private var cancellables = Set<AnyCancellable>()
    
    public init(
        engine: DownloadEngineProtocol = ServiceContainer.shared.downloadEngine,
        hapticService: HapticServiceProtocol = ServiceContainer.shared.hapticService
    ) {
        self.engine = engine
        self.hapticService = hapticService
        
        engine.tasksPublisher
            .map { tasks in tasks.filter { $0.status == .completed } }
            .receive(on: DispatchQueue.main)
            .assign(to: &$completedTasks)
    }
    
    public func clearAllHistory() {
        for task in completedTasks {
            engine.deleteDownload(id: task.id, deleteFile: false)
        }
        hapticService.notificationOccurred(.warning)
    }
    
    public func deleteHistoryItem(_ task: DownloadTaskModel, deleteFile: Bool) {
        engine.deleteDownload(id: task.id, deleteFile: deleteFile)
    }
}
