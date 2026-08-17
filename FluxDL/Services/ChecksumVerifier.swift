import Foundation
import CryptoKit

public enum HashAlgorithm: String, CaseIterable, Identifiable {
    case sha256 = "SHA-256"
    case md5 = "MD5"
    
    public var id: String { rawValue }
}

public enum ChecksumVerifier {
    /// Computes the cryptographic checksum (SHA-256 or MD5) of a local file.
    public static func computeHash(for fileURL: URL, algorithm: HashAlgorithm) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while case let buffer = fileHandle.readData(ofLength: 1024 * 1024), !buffer.isEmpty {
                hasher.update(data: buffer)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()
            
        case .md5:
            var hasher = Insecure.MD5()
            while case let buffer = fileHandle.readData(ofLength: 1024 * 1024), !buffer.isEmpty {
                hasher.update(data: buffer)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()
        }
    }
    
    /// Verifies if a file matches an expected hash string (case-insensitive).
    public static func verify(fileURL: URL, expectedHash: String, algorithm: HashAlgorithm) throws -> Bool {
        let computed = try computeHash(for: fileURL, algorithm: algorithm)
        return computed.lowercased() == expectedHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
