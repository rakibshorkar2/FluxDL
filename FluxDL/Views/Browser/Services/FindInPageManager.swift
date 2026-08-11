import Foundation
import WebKit
import Combine

@MainActor
public final class FindInPageManager: ObservableObject {
    @Published public var searchText: String = ""
    @Published public var matchCount: Int = 0
    @Published public var currentMatchIndex: Int = 0
    @Published var isSearching: Bool = false
    
    private weak var webView: WKWebView?
    
    public init() {}
    
    public func setWebView(_ webView: WKWebView?) {
        self.webView = webView
    }
    
    public func search() {
        guard let webView = webView, !searchText.isEmpty else {
            clearSearch()
            return
        }
        
        // Escape the query both as a regex (literal matching) and as a JS
        // string literal so metacharacters like `\`, `(`, `[` can never
        // break the RegExp or inject script.
        let escaped = NSRegularExpression.escapedPattern(for: searchText)
        let jsLiteral = escaped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        
        let js = """
        (function(text) {
            window.findInPageMatches = window.findInPageMatches || [];
            // Remove previous highlights
            var spans = document.querySelectorAll('.fluxdl-highlight');
            spans.forEach(function(s) {
                var parent = s.parentNode;
                parent.replaceChild(document.createTextNode(s.innerText), s);
                parent.normalize();
            });
            if (!text) return 0;
            
            var body = document.body;
            var regex = new RegExp(text, 'gi');
            var matches = 0;
            
            function highlightNode(node) {
                if (node.nodeType === 3) {
                    var match = node.nodeValue.match(regex);
                    if (match) {
                        var span = document.createElement('span');
                        span.className = 'fluxdl-highlight';
                        span.style.backgroundColor = 'yellow';
                        span.style.color = 'black';
                        span.innerText = node.nodeValue;
                        node.parentNode.replaceChild(span, node);
                        matches++;
                    }
                } else if (node.nodeType === 1 && node.childNodes && !/(script|style)/i.test(node.tagName)) {
                    for (var i = 0; i < node.childNodes.length; i++) {
                        highlightNode(node.childNodes[i]);
                    }
                }
            }
            highlightNode(body);
            return matches;
        })("\(jsLiteral)");
        """
        
        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                if let count = result as? Int {
                    self?.matchCount = count
                    self?.currentMatchIndex = count > 0 ? 1 : 0
                }
            }
        }
    }
    
    public func nextMatch() {
        guard matchCount > 0 else { return }
        currentMatchIndex = (currentMatchIndex % matchCount) + 1
        scrollToCurrentMatch()
    }
    
    public func previousMatch() {
        guard matchCount > 0 else { return }
        currentMatchIndex = currentMatchIndex > 1 ? currentMatchIndex - 1 : matchCount
        scrollToCurrentMatch()
    }
    
    public func clearSearch() {
        searchText = ""
        matchCount = 0
        currentMatchIndex = 0
        isSearching = false
        
        let js = """
        (function() {
            var spans = document.querySelectorAll('.fluxdl-highlight');
            spans.forEach(function(s) {
                var parent = s.parentNode;
                parent.replaceChild(document.createTextNode(s.innerText), s);
                parent.normalize();
            });
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func scrollToCurrentMatch() {
        let js = """
        (function(index) {
            var spans = document.querySelectorAll('.fluxdl-highlight');
            if (spans.length >= index && index > 0) {
                var target = spans[index - 1];
                target.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
        })(\(currentMatchIndex));
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}
