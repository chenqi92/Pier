import SwiftUI

/// Renders markdown content for inline use (e.g., AI chat bubbles).
/// Uses the WKWebView-based MarkdownWebViewSized for full GFM support
/// while measuring content height for proper sizing.
struct MarkdownRenderView: View {
    let content: String
    @State private var contentHeight: CGFloat = 40

    var body: some View {
        MarkdownWebViewSized(
            content: content,
            fontSize: 11,
            measuredHeight: $contentHeight
        )
        .frame(height: max(contentHeight, 20))
    }
}
