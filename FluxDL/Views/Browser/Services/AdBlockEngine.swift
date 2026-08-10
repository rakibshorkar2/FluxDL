import Foundation
import WebKit

/// Receives block-count messages posted by the in-page counting script and
/// forwards them to the engine. Retained by `AdBlockEngine` so it stays alive
/// for every `WKUserContentController` that registers it.
public final class AdBlockMessageHandler: NSObject, WKScriptMessageHandler {
    public var onBlockedURL: ((String) -> Void)?

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == AdBlockEngine.counterScriptMessageName,
              let urlString = message.body as? String else { return }
        onBlockedURL?(urlString)
    }
}

public final class AdBlockEngine {
    public static let shared = AdBlockEngine()

    /// Message-handler name used by the in-page request-counting script.
    public static let counterScriptMessageName = "fluxdlAdCounter"
    /// Posted whenever a request matching the ad rules is reported.
    /// User-info key "host" carries the host of the blocked URL.
    public static let blockedRequestCountDidChangeNotification = Notification.Name("FluxDLAdBlockCountDidChange")

    /// Passive user script that mirrors the content rule list patterns and
    /// reports matching requests to Swift so the UI can surface a per-page
    /// counter. It never modifies page behavior — blocking stays in the
    /// WKContentRuleList, this only observes.
    public static let countingScriptSource = """
    (function () {
        if (window.__fluxdlAdCounterInstalled__) { return; }
        window.__fluxdlAdCounterInstalled__ = true;
        var patterns = [
            /(doubleclick|adservice|googlesyndication|adnxs|amazon-adsystem|popads|popcash|coinhive|coin-hive|outbrain|taboola|zergnet)/i,
            /(adserver|adtracker|analytics-engine|crypto-miner|malicious-redirect)/i
        ];
        function report(url) {
            try {
                var s = String(url);
                for (var i = 0; i < patterns.length; i++) {
                    if (patterns[i].test(s)) {
                        window.webkit.messageHandlers.fluxdlAdCounter.postMessage(s);
                        return;
                    }
                }
            } catch (e) {}
        }
        var nativeOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
            report(url);
            return nativeOpen.apply(this, arguments);
        };
        var nativeFetch = window.fetch;
        if (typeof nativeFetch === "function") {
            window.fetch = function (input, init) {
                var url = typeof input === "string" ? input : (input && input.url) || "";
                report(url);
                return nativeFetch.apply(this, arguments);
            };
        }
    })();
    """

    /// Retained message handler; safe to register on many web views at once.
    public let blockedRequestHandler = AdBlockMessageHandler()

    private var ruleList: WKContentRuleList?
    private var isCompiling = false
    private let lock = NSLock()
    private var blockedCounts: [String: Int] = [:]

    private init() {
        blockedRequestHandler.onBlockedURL = { [weak self] urlString in
            guard let host = URL(string: urlString)?.host else { return }
            self?.registerBlockedRequest(forHost: host)
        }
        compileRules()
    }

    /// Whether ad protection (rule list + request counting) should apply to a domain.
    public func shouldApplyProtection(domain: String?) -> Bool {
        guard BrowserSettings.shared.isAdBlockerEnabled else { return false }
        if let domain = domain, BrowserSettings.shared.isWhitelisted(domain: domain) {
            return false
        }
        return true
    }

    public func applyRuleList(to configuration: WKWebViewConfiguration, domain: String? = nil) {
        guard shouldApplyProtection(domain: domain) else { return }
        if let ruleList = ruleList {
            configuration.userContentController.add(ruleList)
        }
    }

    /// Records a blocked request for the given host and notifies observers.
    public func registerBlockedRequest(forHost host: String) {
        lock.lock()
        blockedCounts[host, default: 0] += 1
        lock.unlock()
        NotificationCenter.default.post(
            name: Self.blockedRequestCountDidChangeNotification,
            object: nil,
            userInfo: ["host": host]
        )
    }

    /// Number of reported blocked requests for a host (0 when unknown).
    public func blockedCount(forHost host: String?) -> Int {
        guard let host else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return blockedCounts[host] ?? 0
    }

    /// Resets the counter for a host (called when a new page starts loading).
    public func resetCount(forHost host: String?) {
        guard let host else { return }
        lock.lock()
        blockedCounts[host] = 0
        lock.unlock()
    }

    private func compileRules() {
        guard ruleList == nil, !isCompiling else { return }
        isCompiling = true

        let jsonRules = """
        [
            {
                "trigger": { "url-filter": ".*(doubleclick|adservice|googlesyndication|adnxs|amazon-adsystem|popads|popcash|coinhive|coin-hive|outbrain|taboola|zergnet).*" },
                "action": { "type": "block" }
            },
            {
                "trigger": { "url-filter": ".*(adserver|adtracker|analytics-engine|crypto-miner|malicious-redirect).*" },
                "action": { "type": "block" }
            },
            {
                "trigger": { "url-filter": ".*", "if-domain": ["*ad.*", "*ads.*"] },
                "action": { "type": "block" }
            }
        ]
        """

        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "FluxDLAdBlockRules",
            encodedContentRuleList: jsonRules
        ) { [weak self] list, error in
            self?.isCompiling = false
            if let list = list {
                self?.ruleList = list
                print("FluxDL AdBlockEngine: Compiled WKContentRuleList successfully.")
            } else if let error = error {
                print("FluxDL AdBlockEngine error: \(error.localizedDescription)")
            }
        }
    }
}
