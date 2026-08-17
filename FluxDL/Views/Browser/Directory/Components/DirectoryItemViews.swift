import SwiftUI

/// Row / cell used by both the list and the grid. Tapping selects in
/// selection mode; otherwise directories navigate, media plays, archives and
/// documents open the action sheet.
public struct DirectoryItemRow: View {
    let item: DirectoryItem
    let isSelected: Bool
    let isSelecting: Bool
    let isSearchMode: Bool
    /// Transient highlight when the row is a freshly located AI search result.
    let isHighlighted: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void
    let onCopyName: () -> Void
    let onResolveSize: () -> Void
    let onDownloadFolder: () -> Void
    let onBookmark: () -> Void

    public init(
        item: DirectoryItem,
        isSelected: Bool,
        isSelecting: Bool,
        isSearchMode: Bool = false,
        isHighlighted: Bool = false,
        onOpen: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onCopyName: @escaping () -> Void = {},
        onResolveSize: @escaping () -> Void = {},
        onDownloadFolder: @escaping () -> Void = {},
        onBookmark: @escaping () -> Void = {}
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isSelecting = isSelecting
        self.isSearchMode = isSearchMode
        self.isHighlighted = isHighlighted
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
        self.onCopyName = onCopyName
        self.onResolveSize = onResolveSize
        self.onDownloadFolder = onDownloadFolder
        self.onBookmark = onBookmark
    }

    public var body: some View {
        Button(action: isSelecting ? onToggleSelection : onOpen) {
            HStack(alignment: .center, spacing: 12) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }

                DirectoryItemThumbnail(item: item, size: 42)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(isSelecting && isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1...3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isSearchMode {
                        HStack(spacing: 5) {
                            if item.type == .directory {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                if let count = item.childCount {
                                    Text("\(count) items")
                                }
                            } else {
                                Text(DirectoryItemFormatter.formattedFileSize(item.sizeBytes))
                                if let date = item.modifiedDate {
                                    Text(DirectoryItemFormatter.string(fromDate: date) ?? "")
                                }
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if item.type != .directory {
                    Button {
                        onDownload()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelecting)
                    .opacity(isSelecting ? 0 : 1)
                    .accessibilityLabel("Download \(item.name)")
                }

                if item.type == .directory {
                    Button {
                        onDownloadFolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelecting)
                    .opacity(isSelecting ? 0 : 1)
                    .accessibilityLabel("Download \(item.name) folder")
                }

                if !isSelecting {
                    Menu {
                        if item.type.isPlayableMedia {
                            Button {
                                onOpen()
                            } label: {
                                Label("Play", systemImage: "play.circle")
                            }
                        }
                        if item.type == .directory {
                            Button {
                                onDownloadFolder()
                            } label: {
                                Label("Download Folder", systemImage: "folder.badge.plus")
                            }
                        } else {
                            Button {
                                onDownload()
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            Button {
                                onShare()
                            } label: {
                                Label("Share Link", systemImage: "square.and.arrow.up")
                            }
                            if item.sizeBytes == nil {
                                Button {
                                    onResolveSize()
                                } label: {
                                    Label("Get Size", systemImage: "ruler")
                                }
                            }
                        }
                        Button {
                            onBookmark()
                        } label: {
                            Label("Bookmark", systemImage: "bookmark")
                        }
                        Button {
                            onShare()
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                        Button {
                            onCopyName()
                        } label: {
                            Label("Copy Name", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Actions for \(item.name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(item.id)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : isHighlighted
                    ? Color.accentColor.opacity(0.25)
                    : Color.clear
        )
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    if !isSelecting {
                        onToggleSelection()
                    }
                }
        )
        .contextMenu {
            Text(item.name)
                .font(.footnote)
                .textSelection(.enabled)
            if item.type == .directory {
                Button {
                    onDownloadFolder()
                } label: {
                    Label("Download Folder", systemImage: "folder.badge.plus")
                }
            } else {
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                if item.sizeBytes == nil {
                    Button {
                        onResolveSize()
                    } label: {
                        Label("Get Size", systemImage: "ruler")
                    }
                }
            }
            Button {
                onBookmark()
            } label: {
                Label("Bookmark", systemImage: "bookmark")
            }
            Button {
                onShare()
            } label: {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            Button {
                onShare()
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            Button {
                onCopyName()
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
        }
    }
}

/// Grid cell — thumbnail-driven, name below.
public struct DirectoryGridCell: View {
    let item: DirectoryItem
    let isSelected: Bool
    let isSelecting: Bool
    /// Transient highlight when the cell is a freshly located AI search result.
    let isHighlighted: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void
    let onCopyName: () -> Void
    let onResolveSize: () -> Void
    let onDownloadFolder: () -> Void
    let onBookmark: () -> Void

    public init(
        item: DirectoryItem,
        isSelected: Bool,
        isSelecting: Bool,
        isHighlighted: Bool = false,
        onOpen: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onCopyName: @escaping () -> Void = {},
        onResolveSize: @escaping () -> Void = {},
        onDownloadFolder: @escaping () -> Void = {},
        onBookmark: @escaping () -> Void = {}
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isSelecting = isSelecting
        self.isHighlighted = isHighlighted
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
        self.onCopyName = onCopyName
        self.onResolveSize = onResolveSize
        self.onDownloadFolder = onDownloadFolder
        self.onBookmark = onBookmark
    }

    public var body: some View {
        Button(action: isSelecting ? onToggleSelection : onOpen) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    DirectoryItemThumbnail(item: item, size: 96)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                            .padding(4)
                            .accessibilityHidden(true)
                    }
                }

                Text(item.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1...3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)

                if item.type == .directory, let count = item.childCount {
                    Text("\(count) items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(DirectoryItemFormatter.formattedFileSize(item.sizeBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : isHighlighted
                                ? Color.accentColor.opacity(0.25)
                                : Color(uiColor: .tertiarySystemFill)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isHighlighted && !isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .id(item.id)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    if !isSelecting {
                        onToggleSelection()
                    }
                }
        )
        .contextMenu {
            Text(item.name)
                .font(.footnote)
                .textSelection(.enabled)
            if item.type == .directory {
                Button {
                    onDownloadFolder()
                } label: {
                    Label("Download Folder", systemImage: "folder.badge.plus")
                }
            } else {
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                if item.sizeBytes == nil {
                    Button {
                        onResolveSize()
                    } label: {
                        Label("Get Size", systemImage: "ruler")
                    }
                }
            }
            Button {
                onBookmark()
            } label: {
                Label("Bookmark", systemImage: "bookmark")
            }
            Button {
                onShare()
            } label: {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            Button {
                onCopyName()
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
        }
    }
}

/// List container.
public struct DirectoryListView: View {
    let items: [DirectoryItem]
    let isSelecting: Bool
    let selectedIDs: Set<UUID>
    /// When set, the listing scrolls to and highlights that item (AI search).
    let highlightedItemID: UUID?
    let onOpen: (DirectoryItem) -> Void
    let onToggleSelection: (DirectoryItem) -> Void
    let onDownload: (DirectoryItem) -> Void
    let onShare: (DirectoryItem) -> Void
    let onCopyName: (DirectoryItem) -> Void
    let onResolveSize: (DirectoryItem) -> Void
    let onDownloadFolder: (DirectoryItem) -> Void
    let onBookmark: (DirectoryItem) -> Void

    public init(
        items: [DirectoryItem],
        isSelecting: Bool,
        selectedIDs: Set<UUID>,
        highlightedItemID: UUID? = nil,
        onOpen: @escaping (DirectoryItem) -> Void,
        onToggleSelection: @escaping (DirectoryItem) -> Void,
        onDownload: @escaping (DirectoryItem) -> Void,
        onShare: @escaping (DirectoryItem) -> Void,
        onCopyName: @escaping (DirectoryItem) -> Void,
        onResolveSize: @escaping (DirectoryItem) -> Void,
        onDownloadFolder: @escaping (DirectoryItem) -> Void = { _ in },
        onBookmark: @escaping (DirectoryItem) -> Void = { _ in }
    ) {
        self.items = items
        self.isSelecting = isSelecting
        self.selectedIDs = selectedIDs
        self.highlightedItemID = highlightedItemID
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
        self.onCopyName = onCopyName
        self.onResolveSize = onResolveSize
        self.onDownloadFolder = onDownloadFolder
        self.onBookmark = onBookmark
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        DirectoryItemRow(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            isSelecting: isSelecting,
                            isHighlighted: highlightedItemID == item.id,
                            onOpen: { onOpen(item) },
                            onToggleSelection: { onToggleSelection(item) },
                            onDownload: { onDownload(item) },
                            onShare: { onShare(item) },
                            onCopyName: { onCopyName(item) },
                            onResolveSize: { onResolveSize(item) },
                            onDownloadFolder: { onDownloadFolder(item) },
                            onBookmark: { onBookmark(item) }
                        )
                        Divider()
                            .padding(.leading, 66)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: highlightedItemID) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

/// Grid container — 3 columns on compact, 4 on regular width.
public struct DirectoryGridView: View {
    let items: [DirectoryItem]
    let isSelecting: Bool
    let selectedIDs: Set<UUID>
    /// When set, the grid scrolls to and highlights that item (AI search).
    let highlightedItemID: UUID?
    let onOpen: (DirectoryItem) -> Void
    let onToggleSelection: (DirectoryItem) -> Void
    let onDownload: (DirectoryItem) -> Void
    let onShare: (DirectoryItem) -> Void
    let onCopyName: (DirectoryItem) -> Void
    let onResolveSize: (DirectoryItem) -> Void
    let onDownloadFolder: (DirectoryItem) -> Void
    let onBookmark: (DirectoryItem) -> Void

    public init(
        items: [DirectoryItem],
        isSelecting: Bool,
        selectedIDs: Set<UUID>,
        highlightedItemID: UUID? = nil,
        onOpen: @escaping (DirectoryItem) -> Void,
        onToggleSelection: @escaping (DirectoryItem) -> Void,
        onDownload: @escaping (DirectoryItem) -> Void,
        onShare: @escaping (DirectoryItem) -> Void,
        onCopyName: @escaping (DirectoryItem) -> Void,
        onResolveSize: @escaping (DirectoryItem) -> Void,
        onDownloadFolder: @escaping (DirectoryItem) -> Void = { _ in },
        onBookmark: @escaping (DirectoryItem) -> Void = { _ in }
    ) {
        self.items = items
        self.isSelecting = isSelecting
        self.selectedIDs = selectedIDs
        self.highlightedItemID = highlightedItemID
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
        self.onCopyName = onCopyName
        self.onResolveSize = onResolveSize
        self.onDownloadFolder = onDownloadFolder
        self.onBookmark = onBookmark
    }

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)
    ]

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { item in
                        DirectoryGridCell(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            isSelecting: isSelecting,
                            isHighlighted: highlightedItemID == item.id,
                            onOpen: { onOpen(item) },
                            onToggleSelection: { onToggleSelection(item) },
                            onDownload: { onDownload(item) },
                            onShare: { onShare(item) },
                            onCopyName: { onCopyName(item) },
                            onResolveSize: { onResolveSize(item) },
                            onDownloadFolder: { onDownloadFolder(item) },
                            onBookmark: { onBookmark(item) }
                        )
                    }
                }
                .padding(10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: highlightedItemID) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

/// Thumbnail for images (and videos via the directory's own downsampling
/// loader); folders and other types get a tinted icon.
public struct DirectoryItemThumbnail: View {
    let item: DirectoryItem
    let size: CGFloat

    public init(item: DirectoryItem, size: CGFloat) {
        self.item = item
        self.size = size
    }

    public var body: some View {
        Group {
            if item.type == .directory {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        Image(systemName: "folder.fill")
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(Color.accentColor)
                    )
            } else if item.type == .image || item.type == .video {
                DirectoryThumbnailImage(url: item.url, type: item.type, size: size)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay(
                        Image(systemName: item.type.systemImage)
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(item.type == .video ? Color.pink : Color.secondary)
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Async thumbnail backed by `DirectoryThumbnailLoader` (ImageIO downsample,
/// NSCache, proxy-aware, `.task(id:)` cancellation).
public struct DirectoryThumbnailImage: View {
    let url: URL
    let type: DirectoryItemType
    let size: CGFloat

    @State private var uiImage: UIImage?

    public init(url: URL, type: DirectoryItemType, size: CGFloat) {
        self.url = url
        self.type = type
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: type == .video ? "film" : "photo")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            uiImage = await DirectoryThumbnailLoader.shared.thumbnail(for: url)
        }
    }
}