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
    private var customRuleList: WKContentRuleList?
    private var isCompiling = false
    private let lock = NSLock()
    private var blockedCounts: [String: Int] = [:]

    private init() {
        blockedRequestHandler.onBlockedURL = { [weak self] urlString in
            guard let host = URL(string: urlString)?.host else { return }
            self?.registerBlockedRequest(forHost: host)
        }
        compileRules()
        reloadCustomRules()
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
        if let customRuleList = customRuleList {
            configuration.userContentController.add(customRuleList)
        }
    }

    /// Recompiles the user-defined block rules. Call whenever
    /// `BrowserSettings.customBlockRules` changes.
    public func reloadCustomRules() {
        let rules = BrowserSettings.shared.customBlockRules
        guard !rules.isEmpty else {
            customRuleList = nil
            return
        }

        let json = Self.customRulesJSON(from: rules)
        guard let store = WKContentRuleListStore.default() else { return }
        // WebKit rejects recompiling an identifier that already exists, so
        // remove the previous version first, then compile the new one.
        store.removeContentRuleList(forIdentifier: Self.customRulesListIdentifier) { [weak self] _ in
            store.compileContentRuleList(
                forIdentifier: Self.customRulesListIdentifier,
                encodedContentRuleList: json
            ) { list, error in
                if let list = list {
                    self?.customRuleList = list
                    print("FluxDL AdBlockEngine: Compiled \(rules.count) custom block rules.")
                } else if let error = error {
                    print("FluxDL AdBlockEngine custom rules error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Identifier for the compiled list of user-defined rules.
    public static let customRulesListIdentifier = "FluxDLCustomBlockRules"

    /// Builds a WKContentRuleList JSON array from user patterns. Each pattern
    /// is matched anywhere in the URL; `*` acts as a wildcard and all other
    /// regex metacharacters are escaped so invalid input can't break a page.
    public static func customRulesJSON(from patterns: [String]) -> String {
        var rules: [String] = []
        for pattern in patterns {
            let sanitized = sanitizedURLPattern(pattern)
            guard !sanitized.isEmpty else { continue }
            rules.append("""
            {"trigger":{"url-filter":".*\(sanitized).*"},"action":{"type":"block"}}
            """)
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// Escapes regex metacharacters (except the `*` wildcard, which becomes
    /// `.*`) so a raw user pattern can be embedded safely in a rule filter.
    public static func sanitizedURLPattern(_ pattern: String) -> String {
        var escaped = pattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: "\u{1}WILD\u{1}")
        escaped = NSRegularExpression.escapedPattern(for: escaped)
        return escaped.replacingOccurrences(of: "\u{1}WILD\u{1}", with: ".*")
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
                "trigger": { "url-filter": ".*(doubleclick|googlesyndication|googletagservices|googleadservices|adservice|adnxs|amazon-adsystem|popads|popcash|coinhive|coin-hive|outbrain|taboola|zergnet).*" },
                "action": { "type": "block" }
            },
            {
                "trigger": { "url-filter": ".*(adserver|adtracker|analytics-engine|crypto-miner|malicious-redirect|pubmatic|criteo|rubicon|casalemedia|moatads|adcolony|unityads|chartbeat|scorecardresearch).*" },
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
