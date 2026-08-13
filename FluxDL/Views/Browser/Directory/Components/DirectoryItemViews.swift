import SwiftUI

/// Row / cell used by both the list and the grid. Tapping selects in
/// selection mode; otherwise directories navigate, media plays, archives and
/// documents open the action sheet.
public struct DirectoryItemRow: View {
    let item: DirectoryItem
    let isSelected: Bool
    let isSelecting: Bool
    let isSearchMode: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void

    public init(
        item: DirectoryItem,
        isSelected: Bool,
        isSelecting: Bool,
        isSearchMode: Bool = false,
        onOpen: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onShare: @escaping () -> Void
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isSelecting = isSelecting
        self.isSearchMode = isSearchMode
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
    }

    public var body: some View {
        Button(action: isSelecting ? onToggleSelection : onOpen) {
            HStack(spacing: 12) {
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
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !isSearchMode {
                        HStack(spacing: 5) {
                            if item.type == .directory {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                if let count = item.childCount {
                                    Text("\(count) items")
                                }
                            } else {
                                if let size = item.sizeBytes {
                                    Text(DirectoryItemFormatter.string(fromBytes: size))
                                }
                                if let date = item.modifiedDate {
                                    Text(DirectoryItemFormatter.string(fromDate: date))
                                }
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

                if !isSelecting {
                    Menu {
                        if item.type.isPlayableMedia {
                            Button {
                                onOpen()
                            } label: {
                                Label("Play", systemImage: "play.circle")
                            }
                        }
                        if item.type != .directory {
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
                        }
                        Button {
                            onShare()
                        } label: {
                            Label("Copy Link", systemImage: "link")
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
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    if !isSelecting {
                        onToggleSelection()
                    }
                }
        )
        .contextMenu {
            if item.type != .directory {
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
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
        }
    }
}

/// Grid cell — thumbnail-driven, name below.
public struct DirectoryGridCell: View {
    let item: DirectoryItem
    let isSelected: Bool
    let isSelecting: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void

    public init(
        item: DirectoryItem,
        isSelected: Bool,
        isSelecting: Bool,
        onOpen: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onShare: @escaping () -> Void
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isSelecting = isSelecting
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
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
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if item.type == .directory, let count = item.childCount {
                    Text("\(count) items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let size = item.sizeBytes {
                    Text(DirectoryItemFormatter.string(fromBytes: size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    if !isSelecting {
                        onToggleSelection()
                    }
                }
        )
        .contextMenu {
            if item.type != .directory {
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            Button {
                onShare()
            } label: {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// List container.
public struct DirectoryListView: View {
    let items: [DirectoryItem]
    let isSelecting: Bool
    let selectedIDs: Set<UUID>
    let onOpen: (DirectoryItem) -> Void
    let onToggleSelection: (DirectoryItem) -> Void
    let onDownload: (DirectoryItem) -> Void
    let onShare: (DirectoryItem) -> Void

    public init(
        items: [DirectoryItem],
        isSelecting: Bool,
        selectedIDs: Set<UUID>,
        onOpen: @escaping (DirectoryItem) -> Void,
        onToggleSelection: @escaping (DirectoryItem) -> Void,
        onDownload: @escaping (DirectoryItem) -> Void,
        onShare: @escaping (DirectoryItem) -> Void
    ) {
        self.items = items
        self.isSelecting = isSelecting
        self.selectedIDs = selectedIDs
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    DirectoryItemRow(
                        item: item,
                        isSelected: selectedIDs.contains(item.id),
                        isSelecting: isSelecting,
                        onOpen: { onOpen(item) },
                        onToggleSelection: { onToggleSelection(item) },
                        onDownload: { onDownload(item) },
                        onShare: { onShare(item) }
                    )
                    Divider()
                        .padding(.leading, 66)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Grid container — 3 columns on compact, 4 on regular width.
public struct DirectoryGridView: View {
    let items: [DirectoryItem]
    let isSelecting: Bool
    let selectedIDs: Set<UUID>
    let onOpen: (DirectoryItem) -> Void
    let onToggleSelection: (DirectoryItem) -> Void
    let onDownload: (DirectoryItem) -> Void
    let onShare: (DirectoryItem) -> Void

    public init(
        items: [DirectoryItem],
        isSelecting: Bool,
        selectedIDs: Set<UUID>,
        onOpen: @escaping (DirectoryItem) -> Void,
        onToggleSelection: @escaping (DirectoryItem) -> Void,
        onDownload: @escaping (DirectoryItem) -> Void,
        onShare: @escaping (DirectoryItem) -> Void
    ) {
        self.items = items
        self.isSelecting = isSelecting
        self.selectedIDs = selectedIDs
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection
        self.onDownload = onDownload
        self.onShare = onShare
    }

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)
    ]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    DirectoryGridCell(
                        item: item,
                        isSelected: selectedIDs.contains(item.id),
                        isSelecting: isSelecting,
                        onOpen: { onOpen(item) },
                        onToggleSelection: { onToggleSelection(item) },
                        onDownload: { onDownload(item) },
                        onShare: { onShare(item) }
                    )
                }
            }
            .padding(10)
        }
        .scrollDismissesKeyboard(.interactively)
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