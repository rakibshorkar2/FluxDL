import Foundation

public enum SearchEngine: String, CaseIterable, Identifiable, Codable {
    case google = "Google"
    case duckDuckGo = "DuckDuckGo"
    case bing = "Bing"
    case ecosia = "Ecosia"
    
    public var id: String { rawValue }
    
    public func searchURL(for query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .google:
            return URL(string: "https://www.google.com/search?q=\(encoded)")!
        case .duckDuckGo:
            return URL(string: "https://duckduckgo.com/?q=\(encoded)")!
        case .bing:
            return URL(string: "https://www.bing.com/search?q=\(encoded)")!
        case .ecosia:
            return URL(string: "https://www.ecosia.org/search?q=\(encoded)")!
        }
    }
}

public final class BrowserSettings: ObservableObject {
    public static let shared = BrowserSettings()
    
    @Published public var homepage: String {
        didSet { UserDefaults.standard.set(homepage, forKey: "browser_homepage") }
    }
    
    @Published public var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "browser_search_engine") }
    }
    
    @Published public var isJavaScriptEnabled: Bool {
        didSet { UserDefaults.standard.set(isJavaScriptEnabled, forKey: "browser_js_enabled") }
    }
    
    @Published public var isPopupBlockingEnabled: Bool {
        didSet { UserDefaults.standard.set(isPopupBlockingEnabled, forKey: "browser_popup_blocking") }
    }
    
    @Published public var isAdBlockerEnabled: Bool {
        didSet { UserDefaults.standard.set(isAdBlockerEnabled, forKey: "browser_ad_blocker") }
    }
    
    @Published public var requestDesktopByDefault: Bool {
        didSet { UserDefaults.standard.set(requestDesktopByDefault, forKey: "browser_request_desktop_default") }
    }
    
    @Published public var adBlockWhitelist: [String] {
        didSet { UserDefaults.standard.set(adBlockWhitelist, forKey: "browser_adblock_whitelist") }
    }
    
    private init() {
        self.homepage = UserDefaults.standard.string(forKey: "browser_homepage") ?? "https://google.com"
        
        if let engineRaw = UserDefaults.standard.string(forKey: "browser_search_engine"),
           let engine = SearchEngine(rawValue: engineRaw) {
            self.searchEngine = engine
        } else {
            self.searchEngine = .google
        }
        
        self.isJavaScriptEnabled = UserDefaults.standard.object(forKey: "browser_js_enabled") != nil
            ? UserDefaults.standard.bool(forKey: "browser_js_enabled") : true
            
        self.isPopupBlockingEnabled = UserDefaults.standard.object(forKey: "browser_popup_blocking") != nil
            ? UserDefaults.standard.bool(forKey: "browser_popup_blocking") : true
            
        self.isAdBlockerEnabled = UserDefaults.standard.object(forKey: "browser_ad_blocker") != nil
            ? UserDefaults.standard.bool(forKey: "browser_ad_blocker") : true
            
        self.requestDesktopByDefault = UserDefaults.standard.bool(forKey: "browser_request_desktop_default")
        
        self.adBlockWhitelist = UserDefaults.standard.stringArray(forKey: "browser_adblock_whitelist") ?? []
    }
    
    public func isWhitelisted(domain: String) -> Bool {
        let clean = domain.lowercased()
        return adBlockWhitelist.contains { clean.contains($0.lowercased()) }
    }
    
    public func toggleWhitelist(domain: String) {
        let clean = domain.lowercased()
        if isWhitelisted(domain: clean) {
            adBlockWhitelist.removeAll { $0.lowercased() == clean }
        } else {
            adBlockWhitelist.append(clean)
        }
    }
}
