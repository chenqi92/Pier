import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "com.kkape.pier", category: "MarkdownWebView")

// MARK: - Shared Resource Loader

/// Loads bundled JS/CSS resources for the Markdown renderer.
/// Uses Bundle.module (SPM) with flat fallback since .process() flattens directories.
private func loadBundledResource(name: String, ext: String) -> String {
    // SPM .process("Resources") flattens subdirectories — try flat first
    if let url = Bundle.module.url(forResource: name, withExtension: ext) {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        logger.error("Failed to read resource at \(url.path)")
    }
    // Try with subdirectory as fallback
    if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "markdown") {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        logger.error("Failed to read resource at \(url.path)")
    }
    logger.error("Resource not found: \(name).\(ext)")
    return "/* Resource \(name).\(ext) not found */"
}

/// Safely encode markdown content for embedding in JavaScript.
/// Uses JSON encoding to handle all special characters (backticks, backslashes, quotes, etc.).
private func jsonEncodeContent(_ content: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: content, options: .fragmentsAllowed),
          let encoded = String(data: data, encoding: .utf8) else {
        // Ultimate fallback — escape manually
        return "\"\""
    }
    return encoded
}

// MARK: - Shared CSS

private func sharedCSS(fontSize: CGFloat, transparentBg: Bool = false) -> String {
    """
    :root {
        --bg: \(transparentBg ? "transparent" : "#ffffff");
        --fg: #1f2328;
        --fg-secondary: #636c76;
        --border: #d1d9e0;
        --code-bg: #f6f8fa;
        --blockquote-border: #d1d9e0;
        --blockquote-fg: #636c76;
        --link: #0969da;
        --table-border: #d1d9e0;
        --table-stripe: #f6f8fa;
        --task-check: #0969da;
        --hr-color: #d1d9e0;
    }
    body.dark {
        --bg: \(transparentBg ? "transparent" : "#0d1117");
        --fg: #e6edf3;
        --fg-secondary: #8b949e;
        --border: #30363d;
        --code-bg: #161b22;
        --blockquote-border: #30363d;
        --blockquote-fg: #8b949e;
        --link: #58a6ff;
        --table-border: #30363d;
        --table-stripe: #161b22;
        --task-check: #58a6ff;
        --hr-color: #30363d;
    }
    body.light #hljs-dark { display: none; }
    body.dark #hljs-light { display: none; }

    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        font-size: \(fontSize)px;
        line-height: 1.6;
        color: var(--fg);
        background: var(--bg);
        padding: 16px;
        -webkit-font-smoothing: antialiased;
    }
    h1, h2, h3, h4, h5, h6 {
        margin-top: 24px;
        margin-bottom: 16px;
        font-weight: 600;
        line-height: 1.25;
    }
    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: 0.875em; }
    h6 { font-size: 0.85em; color: var(--fg-secondary); }
    #content > h1:first-child,
    #content > h2:first-child,
    #content > h3:first-child { margin-top: 0; }
    p { margin-bottom: 16px; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { margin-bottom: 16px; padding-left: 2em; }
    li { margin-bottom: 4px; }
    li > ul, li > ol { margin-bottom: 0; margin-top: 4px; }
    ul.contains-task-list { list-style: none; padding-left: 1.5em; }
    .task-list-item { position: relative; }
    .task-list-item input[type="checkbox"] {
        margin-right: 0.5em;
        accent-color: var(--task-check);
    }
    code {
        font-family: "SF Mono", "Menlo", "Monaco", "Courier New", monospace;
        font-size: 0.85em;
        background: var(--code-bg);
        padding: 0.2em 0.4em;
        border-radius: 4px;
    }
    pre {
        position: relative;
        margin-bottom: 16px;
        padding: 16px;
        overflow-x: auto;
        background: var(--code-bg);
        border-radius: 8px;
        border: 1px solid var(--border);
    }
    pre code {
        background: none;
        padding: 0;
        font-size: 0.85em;
        line-height: 1.5;
    }
    /* Copy button */
    .copy-btn {
        position: absolute;
        top: 6px;
        right: 6px;
        padding: 3px 8px;
        font-size: 11px;
        font-family: -apple-system, sans-serif;
        color: var(--fg-secondary);
        background: var(--bg);
        border: 1px solid var(--border);
        border-radius: 5px;
        cursor: pointer;
        opacity: 0;
        transition: opacity 0.15s ease;
        z-index: 1;
        line-height: 1.4;
    }
    pre:hover .copy-btn { opacity: 1; }
    .copy-btn:hover { color: var(--fg); background: var(--table-stripe); }
    .copy-btn.copied { color: #2ea043; border-color: #2ea043; }
    blockquote {
        margin-bottom: 16px;
        padding: 0 1em;
        border-left: 4px solid var(--blockquote-border);
        color: var(--blockquote-fg);
    }
    blockquote > p { margin-bottom: 8px; }
    table {
        width: 100%;
        border-collapse: collapse;
        margin-bottom: 16px;
        font-size: 0.9em;
    }
    th, td {
        padding: 8px 12px;
        border: 1px solid var(--table-border);
        text-align: left;
    }
    th { font-weight: 600; background: var(--table-stripe); }
    tr:nth-child(even) td { background: var(--table-stripe); }
    hr {
        height: 2px;
        border: none;
        background: var(--hr-color);
        margin: 24px 0;
    }
    img {
        max-width: 100%;
        height: auto;
        border-radius: 6px;
        margin: 8px 0;
    }
    del { color: var(--fg-secondary); }
    strong { font-weight: 600; }
    em { font-style: italic; }
    """
}

// MARK: - MarkdownWebView (Full-size, for file preview)

/// A full-featured Markdown renderer using WKWebView with marked.js and highlight.js.
/// Supports all GFM features: tables, code blocks with syntax highlighting, blockquotes,
/// task lists, images, links, strikethrough, nested lists, and more.
struct MarkdownWebView: NSViewRepresentable {
    let content: String
    var fontSize: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "javaScriptEnabled")

        // Register copyCode message handler
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "copyCode")
        config.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let html = buildHTML(content: content)
        logger.info("MarkdownWebView: loading HTML (\(html.count) chars) for content (\(content.count) chars)")
        webView.loadHTMLString(html, baseURL: nil)

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let isDark = colorScheme == .dark
        if coordinator.lastContent != content || coordinator.lastIsDark != isDark || coordinator.lastFontSize != fontSize {
            coordinator.lastContent = content
            coordinator.lastIsDark = isDark
            coordinator.lastFontSize = fontSize

            if coordinator.isPageLoaded {
                updateContentViaJS(webView: webView, content: content, isDark: isDark)
            } else {
                let html = buildHTML(content: content)
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastContent: String = ""
        var lastIsDark: Bool = false
        var lastFontSize: CGFloat = 14
        var isPageLoaded = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            logger.info("MarkdownWebView: page loaded successfully")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("MarkdownWebView: navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.error("MarkdownWebView: provisional navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        // Handle copy-code messages from JS
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "copyCode", let text = message.body as? String {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    // MARK: - JS Content Update

    private func updateContentViaJS(webView: WKWebView, content: String, isDark: Bool) {
        let encoded = jsonEncodeContent(content)
        let js = """
        (function() {
            document.body.className = '\(isDark ? "dark" : "light")';
            document.documentElement.style.fontSize = '\(fontSize)px';
            var raw = \(encoded);
            document.getElementById('content').innerHTML = marked.parse(raw);
            document.querySelectorAll('pre code').forEach(function(block) {
                hljs.highlightElement(block);
            });
            addCopyButtons();
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                logger.error("MarkdownWebView: JS update error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - HTML Builder

    private func buildHTML(content: String) -> String {
        let isDark = colorScheme == .dark
        let markedJS = loadBundledResource(name: "marked.min", ext: "js")
        let hljsJS = loadBundledResource(name: "highlight.min", ext: "js")
        let hljsLightCSS = loadBundledResource(name: "highlight-github.min", ext: "css")
        let hljsDarkCSS = loadBundledResource(name: "highlight-github-dark.min", ext: "css")
        let encoded = jsonEncodeContent(content)
        let css = sharedCSS(fontSize: fontSize)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style id="hljs-light">\(hljsLightCSS)</style>
        <style id="hljs-dark">\(hljsDarkCSS)</style>
        <style>\(css)</style>
        <script>\(markedJS)</script>
        <script>\(hljsJS)</script>
        </head>
        <body class="\(isDark ? "dark" : "light")">
        <div id="content"></div>
        <script>
        function addCopyButtons() {
            document.querySelectorAll('pre').forEach(function(pre) {
                if (pre.querySelector('.copy-btn')) return;
                var btn = document.createElement('button');
                btn.className = 'copy-btn';
                btn.textContent = 'Copy';
                btn.addEventListener('click', function() {
                    var code = pre.querySelector('code');
                    var text = code ? code.textContent : pre.textContent;
                    window.webkit.messageHandlers.copyCode.postMessage(text);
                    btn.textContent = 'Copied!';
                    btn.classList.add('copied');
                    setTimeout(function() {
                        btn.textContent = 'Copy';
                        btn.classList.remove('copied');
                    }, 1500);
                });
                pre.appendChild(btn);
            });
        }
        (function() {
            try {
                marked.setOptions({ gfm: true, breaks: false, pedantic: false });
                var raw = \(encoded);
                document.getElementById('content').innerHTML = marked.parse(raw);
                document.querySelectorAll('pre code').forEach(function(block) {
                    hljs.highlightElement(block);
                });
                addCopyButtons();
            } catch(e) {
                document.getElementById('content').innerHTML =
                    '<pre style="color:red;">Render error: ' + e.message + '</pre>';
            }
        })();
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - MarkdownWebViewSized (for AI chat bubbles, with height measurement)

/// A variant of MarkdownWebView that measures its content height via JavaScript
/// and reports it so the parent can size the view correctly (useful for chat bubbles).
struct MarkdownWebViewSized: NSViewRepresentable {
    let content: String
    var fontSize: CGFloat = 11
    @Binding var measuredHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "javaScriptEnabled")

        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "heightChanged")
        userContentController.add(context.coordinator, name: "copyCode")
        config.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let html = buildHTML(content: content)
        webView.loadHTMLString(html, baseURL: nil)

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let isDark = colorScheme == .dark
        let coordinator = context.coordinator
        if coordinator.lastContent != content || coordinator.lastIsDark != isDark {
            coordinator.lastContent = content
            coordinator.lastIsDark = isDark

            if coordinator.isPageLoaded {
                updateContentViaJS(webView: webView, content: content, isDark: isDark)
            } else {
                let html = buildHTML(content: content)
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: MarkdownWebViewSized
        weak var webView: WKWebView?
        var lastContent: String = ""
        var lastIsDark: Bool = false
        var isPageLoaded = false

        init(parent: MarkdownWebViewSized) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            measureHeight(webView: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "heightChanged",
               let height = message.body as? CGFloat {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.measuredHeight = height
                }
            } else if message.name == "copyCode", let text = message.body as? String {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func measureHeight(webView: WKWebView) {
            let js = "document.body.scrollHeight"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.parent.measuredHeight = height
                    }
                }
            }
        }
    }

    private func updateContentViaJS(webView: WKWebView, content: String, isDark: Bool) {
        let encoded = jsonEncodeContent(content)
        let js = """
        (function() {
            document.body.className = '\(isDark ? "dark" : "light")';
            document.documentElement.style.fontSize = '\(fontSize)px';
            var raw = \(encoded);
            document.getElementById('content').innerHTML = marked.parse(raw);
            document.querySelectorAll('pre code').forEach(function(block) {
                hljs.highlightElement(block);
            });
            addCopyButtons();
            setTimeout(function() {
                window.webkit.messageHandlers.heightChanged.postMessage(document.body.scrollHeight);
            }, 50);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func buildHTML(content: String) -> String {
        let isDark = colorScheme == .dark
        let markedJS = loadBundledResource(name: "marked.min", ext: "js")
        let hljsJS = loadBundledResource(name: "highlight.min", ext: "js")
        let hljsLightCSS = loadBundledResource(name: "highlight-github.min", ext: "css")
        let hljsDarkCSS = loadBundledResource(name: "highlight-github-dark.min", ext: "css")
        let encoded = jsonEncodeContent(content)
        let css = sharedCSS(fontSize: fontSize, transparentBg: true)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style id="hljs-light">\(hljsLightCSS)</style>
        <style id="hljs-dark">\(hljsDarkCSS)</style>
        <style>\(css)</style>
        <script>\(markedJS)</script>
        <script>\(hljsJS)</script>
        </head>
        <body class="\(isDark ? "dark" : "light")">
        <div id="content"></div>
        <script>
        function addCopyButtons() {
            document.querySelectorAll('pre').forEach(function(pre) {
                if (pre.querySelector('.copy-btn')) return;
                var btn = document.createElement('button');
                btn.className = 'copy-btn';
                btn.textContent = 'Copy';
                btn.addEventListener('click', function() {
                    var code = pre.querySelector('code');
                    var text = code ? code.textContent : pre.textContent;
                    window.webkit.messageHandlers.copyCode.postMessage(text);
                    btn.textContent = 'Copied!';
                    btn.classList.add('copied');
                    setTimeout(function() {
                        btn.textContent = 'Copy';
                        btn.classList.remove('copied');
                    }, 1500);
                });
                pre.appendChild(btn);
            });
        }
        (function() {
            try {
                marked.setOptions({ gfm: true, breaks: false });
                var raw = \(encoded);
                document.getElementById('content').innerHTML = marked.parse(raw);
                document.querySelectorAll('pre code').forEach(function(block) {
                    hljs.highlightElement(block);
                });
                addCopyButtons();
                setTimeout(function() {
                    window.webkit.messageHandlers.heightChanged.postMessage(document.body.scrollHeight);
                }, 50);
            } catch(e) {
                document.getElementById('content').innerHTML =
                    '<pre style="color:red;">Render error: ' + e.message + '</pre>';
            }
        })();
        </script>
        </body>
        </html>
        """
    }
}
