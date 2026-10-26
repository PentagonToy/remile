import Foundation

/// Defaults follow each pane's job. User resizing remains local to that workspace.
enum WorkspaceLayout {
    static func navigation(_ width: CGFloat) -> CGFloat { min(280, max(200, width * 0.18)) }
    static func outline(_ width: CGFloat) -> CGFloat { min(250, max(180, width * 0.16)) }
    static func files(_ width: CGFloat) -> CGFloat { min(260, max(180, width * 0.18)) }
    static func results(_ width: CGFloat) -> CGFloat { min(460, max(300, width * 0.32)) }
    static func referenceSide(_ width: CGFloat) -> CGFloat { min(320, max(200, (width - 48) * 0.20)) }
    static let paneNames = ["home sidebar", "reference libraries", "reference preview", "outline", "Markdown editor", "project files", "LaTeX source", "Overleaf tags", "search results", "document sidebar", "Ask panel", "Markdown Ask", "writer tools"]
    static func key(_ label: String) -> String { "layout.pane." + label }
}
