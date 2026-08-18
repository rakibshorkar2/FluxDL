import Foundation

// MARK: - Segment assembly

/// Streaming assembly of completed segment files into the final file, with
/// size validation and atomic finalize. Never loads the whole file into
/// memory: reads/writes in bounded chunks.
public enum SegmentFileAssembler {

    public enum AssemblyError: Error, Equatable {
        case emptySegmentList
        case missingSegmentFile(segmentID: UUID)
        case segmentTooShort(segmentID: UUID, expected: Int64, actual: Int64)
        case segmentTooLong(segmentID: UUID, expected: Int64, actual: Int64)
        case finalSizeMismatch(expected: Int64, actual: Int64)
        case failedToOpenOutput
        case failedToFinalize(underlying: String)
    }

    public struct Plan: Equatable, Sendable {
        public let orderedSegments: [DownloadSegment]
        public let expectedSize: Int64

        /// Validates ordering and coverage without touching the disk.
        public static func validate(segments: [DownloadSegment], expectedSize: Int64) -> Result<Void, AssemblyError> {
            guard !segments.isEmpty else { return .failure(.emptySegmentList) }
            var cursor: Int64 = 0
            for segment in segments.sorted(by: { $0.byteStart < $1.byteStart }) {
                guard segment.byteStart == cursor else {
                    return .failure(.finalSizeMismatch(expected: expectedSize, actual: cursor))
                }
                cursor = segment.byteEnd + 1
            }
            guard cursor == expectedSize else {
                return .failure(.finalSizeMismatch(expected: expectedSize, actual: cursor))
            }
            return .success(())
        }
    }

    public static let chunkSize = 1 << 20 // 1 MiB bounded reads/writes

    /// Concatenates `partDirectory`/`<segmentID>.part` files (in range order)
    /// into `outputURL`, then validates the final size. Does not touch the
    /// destination yet — `finalize` does the atomic move.
    public static func assemble(
        segments: [DownloadSegment],
        partDirectory: URL,
        outputURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let ordered = segments.sorted { $0.byteStart < $1.byteStart }
        if case .failure(let error) = Plan.validate(segments: ordered, expectedSize: ordered.reduce(0) { $0 + $1.expectedBytes }) {
            throw error
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw AssemblyError.failedToOpenOutput
        }
        guard let output = try? FileHandle(forWritingTo: outputURL) else {
            throw AssemblyError.failedToOpenOutput
        }
        defer { try? output.close() }
        do {
            for segment in ordered {
                let partURL = partDirectory
                    .appendingPathComponent(segment.segmentID.uuidString)
                    .appendingPathExtension("part")
                guard let input = try? FileHandle(forReadingFrom: partURL) else {
                    throw AssemblyError.missingSegmentFile(segmentID: segment.segmentID)
                }
                defer { try? input.close() }
                var totalRead: Int64 = 0
                while true {
                    let data = try input.read(upToCount: chunkSize)
                    guard let data, !data.isEmpty else { break }
                    totalRead += Int64(data.count)
                    if totalRead > segment.expectedBytes {
                        throw AssemblyError.segmentTooLong(segmentID: segment.segmentID, expected: segment.expectedBytes, actual: totalRead)
                    }
                    try output.write(contentsOf: data)
                }
                if totalRead != segment.expectedBytes {
                    throw AssemblyError.segmentTooShort(segmentID: segment.segmentID, expected: segment.expectedBytes, actual: totalRead)
                }
            }
        } catch let error as AssemblyError {
            throw error
        } catch {
            throw AssemblyError.failedToFinalize(underlying: error.localizedDescription)
        }
        try output.close()
        let actualSize = (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? -1
        let expected = ordered.reduce(0) { $0 + $1.expectedBytes }
        guard actualSize == expected else {
            throw AssemblyError.finalSizeMismatch(expected: expected, actual: actualSize)
        }
    }

    /// Atomically moves the assembled file to its destination. Existing file
    /// at the destination is replaced only after a successful move into a
    /// sibling temp name, preserving atomicity as much as the OS allows.
    public static func finalize(
        assembledURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let tempSibling = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).fluxdl-finalize.tmp")
        try? fileManager.removeItem(at: tempSibling)
        do {
            try fileManager.moveItem(at: assembledURL, to: tempSibling)
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.moveItem(at: tempSibling, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: tempSibling)
            throw AssemblyError.failedToFinalize(underlying: error.localizedDescription)
        }
    }

    /// Removes the per-task segment directory after successful assembly.
    public static func cleanup(partDirectory: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: partDirectory)
    }
}