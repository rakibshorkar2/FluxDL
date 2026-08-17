import SwiftUI

/// Directory Mode address bar — same visual language as `BrowserAddressBar`
/// (rounded field on tertiary fill, reload/stop chrome button) but with
/// directory semantics: navigating always loads a listing, and the up/back
/// affordances live in the bottom bar.
public struct DirectoryAddressBar: View {
    @Binding var text: String
    let isLoading: Bool
    let isProxied: Bool
    let proxyLabel: String?
    let onCommit: () -> Void
    let onReload: () -> Void

    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        isLoading: Bool,
        isProxied: Bool,
        proxyLabel: String?,
        onCommit: @escaping () -> Void,
        onReload: @escaping () -> Void
    ) {
        self._text = text
        self.isLoading = isLoading
        self.isProxied = isProxied
        self.proxyLabel = proxyLabel
        self.onCommit = onCommit
        self.onReload = onReload
    }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                TextField("Enter directory address", text: $text)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($isFocused)
                    .onSubmit {
                        isFocused = false
                        onCommit()
                    }
                    .accessibilityLabel("Directory address field")

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }

                if isProxied, let label = proxyLabel {
                    HStack(spacing: 3) {
                        Image(systemName: "network")
                        Text(label)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .accessibilityLabel("Proxied through \(label)")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isFocused ? Color.accentColor.opacity(0.7) : Color.clear,
                                lineWidth: 1.5
                            )
                    )
            )

            BrowserChromeButton(
                systemImage: isLoading ? "xmark" : "arrow.clockwise",
                isEnabled: true,
                accessibilityLabel: isLoading ? "Stop Loading" : "Reload",
                action: onReload
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Bottom bar for Directory Mode: back, up, layout toggle, sort menu,
/// bookmarks, history. Replaces the web `BrowserToolbar` while the mode is
/// active.
public struct DirectoryBottomBar: View {
    @ObservedObject var viewModel: DirectoryBrowserViewModel

    public init(viewModel: DirectoryBrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 4) {
            BrowserChromeButton(
                systemImage: "chevron.backward",
                isEnabled: viewModel.canGoBack,
                accessibilityLabel: "Back",
                action: { viewModel.goBack() }
            )

            BrowserChromeButton(
                systemImage: "arrow.up",
                isEnabled: viewModel.canGoUp,
                accessibilityLabel: "Up to Parent Directory",
                action: { viewModel.goUp() }
            )

            Spacer()

            Menu {
                Picker("Sort", selection: $viewModel.sort) {
                    ForEach(DirectorySortOption.allCases, id: \.self) { option in
                        Label(option.title, systemImage: sortImage(option))
                            .tag(option)
                    }
                }
                .onChange(of: viewModel.sort) { _ in viewModel.persistLayoutPreference() }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Sort options")

            BrowserChromeButton(
                systemImage: viewModel.isGridView ? "list.bullet" : "square.grid.2x2",
                isEnabled: true,
                accessibilityLabel: viewModel.isGridView ? "Switch to List" : "Switch to Grid",
                action: {
                    viewModel.isGridView.toggle()
                    viewModel.persistLayoutPreference()
                }
            )

            BrowserChromeButton(
                systemImage: viewModel.isCurrentBookmarked() ? "bookmark.fill" : "bookmark",
                isEnabled: viewModel.currentURL != nil,
                accessibilityLabel: "Bookmark this directory",
                action: { viewModel.bookmarkCurrent() }
            )

            BrowserChromeButton(
                systemImage: "book",
                isEnabled: true,
                accessibilityLabel: "Bookmarks",
                action: { viewModel.isBookmarksPresented = true }
            )

            BrowserChromeButton(
                systemImage: "clock",
                isEnabled: true,
                accessibilityLabel: "Directory History",
                action: { viewModel.isHistoryPresented = true }
            )
        }
        .padding(.horizontal, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func sortImage(_ option: DirectorySortOption) -> String {
        switch option {
        case .foldersFirst: return "folder"
        case .nameAscending: return "textformat"
        case .nameDescending: return "textformat.size"
        case .sizeDescending: return "arrow.down.to.line"
        case .dateDescending: return "calendar"
        }
    }
}

/// Tappable breadcrumbs: Server > Movies > Action > 2026
public struct DirectoryBreadcrumbView: View {
    let breadcrumbs: [DirectoryBreadcrumb]
    let onSelect: (DirectoryBreadcrumb) -> Void

    public init(breadcrumbs: [DirectoryBreadcrumb], onSelect: @escaping (DirectoryBreadcrumb) -> Void) {
        self.breadcrumbs = breadcrumbs
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onSelect(crumb)
                    } label: {
                        Text(crumb.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(index == breadcrumbs.count - 1 ? Color.accentColor : .secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Filename filter — local substring match, never triggers a network call.
public struct DirectoryFilterBar: View {
    @Binding var text: String

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter files", text: $text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Horizontal category chips (All / Movies / Series / Games / Software /
/// Anime / Images). Classification is purely name-keyword based.
public struct DirectoryCategoryPicker: View {
    @Binding var category: DirectoryCategory

    public init(category: Binding<DirectoryCategory>) {
        self._category = category
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(DirectoryCategory.allCases, id: \.self) { option in
                    Button {
                        category = option
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: option.systemImage)
                                .font(.caption2)
                            Text(option.title)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            category == option
                                ? Color.accentColor
                                : Color(uiColor: .tertiarySystemFill),
                            in: Capsule()
                        )
                        .foregroundStyle(category == option ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}

/// Contextual toolbar shown while items are selected.
public struct DirectorySelectionToolbar: View {
    let count: Int
    let onDownload: () -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onCancel: () -> Void

    public init(
        count: Int,
        onDownload: @escaping () -> Void,
        onSelectAll: @escaping () -> Void,
        onDeselectAll: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.count = count
        self.onDownload = onDownload
        self.onSelectAll = onSelectAll
        self.onDeselectAll = onDeselectAll
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("Exit selection mode")

            VStack(alignment: .leading, spacing: 1) {
                Text("Selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.headline.monospacedDigit())
            }

            Spacer()

            Menu {
                Button {
                    onSelectAll()
                } label: {
                    Label("Select All", systemImage: "checkmark.circle")
                }
                Button {
                    onDeselectAll()
                } label: {
                    Label("Deselect All", systemImage: "circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Selection options")

            Button {
                onDownload()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1)
            .accessibilityLabel("Download \(count) selected items")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}