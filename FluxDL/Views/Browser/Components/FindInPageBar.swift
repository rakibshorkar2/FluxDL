import SwiftUI
import Combine

public struct FindInPageBar: View {
    @ObservedObject var manager: FindInPageManager
    let onClose: () -> Void

    // Debounce: only fire search 300 ms after user stops typing.
    // Eliminates full-DOM JS walk on every keystroke which was a major CPU spike.
    @State private var debounceTask: DispatchWorkItem?

    public var body: some View {
        GlassCard(padding: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Find in page...", text: $manager.searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        debounceTask?.cancel()
                        manager.search()
                    }
                    .onChange(of: manager.searchText) { _ in
                        // Cancel any pending search and schedule a new one after 300 ms
                        debounceTask?.cancel()
                        if manager.searchText.isEmpty {
                            manager.clearSearch()
                            return
                        }
                        let work = DispatchWorkItem { manager.search() }
                        debounceTask = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                    }

                if manager.matchCount > 0 {
                    Text("\(manager.currentMatchIndex)/\(manager.matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if !manager.searchText.isEmpty {
                    Text("0 matches")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button(action: { manager.previousMatch() }) {
                    Image(systemName: "chevron.up")
                        .font(.caption.bold())
                }
                .disabled(manager.matchCount == 0)

                Button(action: { manager.nextMatch() }) {
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                }
                .disabled(manager.matchCount == 0)

                Button(action: {
                    debounceTask?.cancel()
                    manager.clearSearch()
                    onClose()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
