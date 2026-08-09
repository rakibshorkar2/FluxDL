import Foundation

public enum URLFilenameExtractor {
    /// Extracts a clean, human-readable filename from a URL (path, query parameters, or service-specific fallbacks)
    /// and optionally from an HTTP Content-Disposition response header.
    public static func extractFilename(from url: URL, contentDisposition: String? = nil) -> String {
        // 1. Try Content-Disposition header if provided
        if let cd = contentDisposition, let name = extractFilename(fromContentDisposition: cd), !name.isEmpty {
            return name
        }
        
        // 2. Check query string parameters (e.g. response-content-disposition, filename, file, name)
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true), let queryItems = components.queryItems {
            for item in queryItems {
                let key = item.name.lowercased()
                if key == "response-content-disposition" || key == "content-disposition", let val = item.value {
                    if let name = extractFilename(fromContentDisposition: val), !name.isEmpty {
                        return name
                    }
                }
                if (key == "filename" || key == "file" || key == "name"), let val = item.value, !val.isEmpty {
                    let cleaned = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"': "))
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }
        
        // 3. Check URL path last component if it has a file extension
        let pathLast = url.lastPathComponent
        let pathExt = (pathLast as NSString).pathExtension
        if !pathLast.isEmpty && !pathExt.isEmpty && pathLast.lowercased() != "download" && pathLast.lowercased() != "archive" {
            return pathLast
        }
        
        // 4. Service-specific fallbacks (Google Drive, Seedr, etc.)
        let host = url.host?.lowercased() ?? ""
        if host.contains("drive.google.com") || host.contains("usercontent.google.com") {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
               let idParam = components.queryItems?.first(where: { $0.name == "id" })?.value {
                return "gdrive_\(idParam.prefix(8))"
            }
            return "gdrive_download"
        }
        
        if host.contains("seedr.cc") {
            let pathSuffix = String(url.path.suffix(8))
            return pathSuffix.isEmpty ? "seedr_archive.zip" : "seedr_\(pathSuffix)"
        }
        
        if !pathLast.isEmpty && pathLast.lowercased() != "download" {
            return pathLast
        }
        
        return "download_\(UUID().uuidString.prefix(6))"
    }
    
    /// Parses Content-Disposition header values like `attachment; filename="file.zip"` or `filename*=UTF-8''file.zip`
    public static func extractFilename(fromContentDisposition cd: String) -> String? {
        // Standard UTF-8 encoded filename*=
        if let range = cd.range(of: "filename*=", options: .caseInsensitive) {
            let substring = String(cd[range.upperBound...])
            let parts = substring.components(separatedBy: "''")
            if parts.count == 2, let decoded = parts[1].removingPercentEncoding {
                let name = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\"'; "))
                if !name.isEmpty { return name }
            }
        }
        
        // Standard filename=
        if let range = cd.range(of: "filename=", options: .caseInsensitive) {
            let substring = String(cd[range.upperBound...])
            let rawName = substring.components(separatedBy: ";").first ?? substring
            let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\"'; "))
            if let decoded = name.removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
            if !name.isEmpty { return name }
        }
        
        return nil
    }
}
