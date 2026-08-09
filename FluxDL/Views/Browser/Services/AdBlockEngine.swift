import Foundation
import WebKit

public final class AdBlockEngine {
    public static let shared = AdBlockEngine()
    private var ruleList: WKContentRuleList?
    private var isCompiling = false
    
    private init() {
        compileRules()
    }
    
    public func applyRuleList(to configuration: WKWebViewConfiguration, domain: String? = nil) {
        guard BrowserSettings.shared.isAdBlockerEnabled else { return }
        if let domain = domain, BrowserSettings.shared.isWhitelisted(domain: domain) {
            return
        }
        if let ruleList = ruleList {
            configuration.userContentController.add(ruleList)
        }
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
