import Foundation

/// Minimal, dependency-free Markdown-to-HTML converter covering the common
/// GitHub-flavored subset: headers, emphasis, code, links, images, lists,
/// blockquotes, tables, horizontal rules and fenced code blocks.
enum MarkdownRenderer {

    static func renderHTML(fromMarkdown markdown: String, title: String) -> String {
        let body = htmlBody(from: markdown)
        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    private static func htmlBody(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var inCodeBlock = false
        var codeLang = ""
        var codeBuffer: [String] = []
        var listStack: [String] = [] // "ul" or "ol"
        var inTable = false

        func closeLists() {
            while let tag = listStack.popLast() {
                out.append("</\(tag)>")
            }
        }
        func closeTable() {
            if inTable {
                out.append("</tbody></table>")
                inTable = false
            }
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw

            // Fenced code blocks
            if let fence = fenceMarker(line) {
                if inCodeBlock {
                    out.append("<pre><code class=\"language-\(escape(codeLang))\">\(codeBuffer.map(escape).joined(separator: "\n"))</code></pre>")
                    codeBuffer = []
                    inCodeBlock = false
                } else {
                    closeLists(); closeTable()
                    inCodeBlock = true
                    codeLang = fence
                }
                i += 1
                continue
            }
            if inCodeBlock {
                codeBuffer.append(raw)
                i += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeLists(); closeTable()
                out.append("<hr>")
                i += 1
                continue
            }

            // Headers
            if let (level, text) = header(trimmed) {
                closeLists(); closeTable()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                closeLists(); closeTable()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                out.append("<blockquote>\(inline(text))</blockquote>")
                i += 1
                continue
            }

            // Tables (header row + separator row)
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                closeLists()
                let headers = tableCells(trimmed)
                out.append("<table><thead><tr>")
                for h in headers { out.append("<th>\(inline(h))</th>") }
                out.append("</tr></thead><tbody>")
                inTable = true
                i += 2
                continue
            }
            if inTable, trimmed.contains("|") {
                let cells = tableCells(trimmed)
                out.append("<tr>")
                for c in cells { out.append("<td>\(inline(c))</td>") }
                out.append("</tr>")
                i += 1
                continue
            } else if inTable {
                closeTable()
            }

            // Lists
            if let (kind, content, _) = listItem(line) {
                if listStack.last != kind {
                    if !listStack.isEmpty { closeLists() }
                    listStack.append(kind)
                    out.append("<\(kind)>")
                }
                out.append("<li>\(inline(content))</li>")
                i += 1
                continue
            } else if !listStack.isEmpty {
                closeLists()
            }

            // Blank line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph
            out.append("<p>\(inline(trimmed))</p>")
            i += 1
        }

        closeLists()
        closeTable()
        if inCodeBlock {
            out.append("<pre><code>\(codeBuffer.map(escape).joined(separator: "\n"))</code></pre>")
        }
        return out.joined(separator: "\n")
    }

    private static func fenceMarker(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") {
            return String(t.dropFirst(3))
        }
        return nil
    }

    private static func header(_ trimmed: String) -> (Int, String)? {
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        let text = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || !t.contains(" ") else { return false }
        let allowed = CharacterSet(charactersIn: "-|: ")
        return t.unicodeScalars.allSatisfy { allowed.contains($0) } && t.contains("-")
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> (String, String, Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return ("ul", String(trimmed.dropFirst(2)), leadingSpaces)
        }
        if let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return ("ol", String(trimmed[range.upperBound...]), leadingSpaces)
        }
        return nil
    }

    /// Inline formatting: code, bold, italic, links, images.
    private static func inline(_ text: String) -> String {
        var s = escape(text)

        // Inline code `code`
        s = replace(s, pattern: #"`([^`]+)`"#) { m in
            "<code>\(m[1])</code>"
        }
        // Images ![alt](url)
        s = replace(s, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { m in
            "<img alt=\"\(m[1])\" src=\"\(m[2])\">"
        }
        // Links [text](url)
        s = replace(s, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { m in
            "<a href=\"\(m[2])\">\(m[1])</a>"
        }
        // Bold **text** or __text__
        s = replace(s, pattern: #"\*\*([^*]+)\*\*"#) { m in "<strong>\(m[1])</strong>" }
        s = replace(s, pattern: #"__([^_]+)__"#) { m in "<strong>\(m[1])</strong>" }
        // Italic *text* or _text_
        s = replace(s, pattern: #"\*([^*]+)\*"#) { m in "<em>\(m[1])</em>" }
        s = replace(s, pattern: #"(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])"#) { m in "<em>\(m[1])</em>" }
        // Strikethrough ~~text~~
        s = replace(s, pattern: #"~~([^~]+)~~"#) { m in "<del>\(m[1])</del>" }

        return s
    }

    private static func replace(_ input: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var lastEnd = 0
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let css = """
    :root { color-scheme: dark; }
    html, body {
        margin: 0; padding: 0;
        background: #0b1220;
        background: linear-gradient(180deg, #0b1220 0%, #0d1526 100%);
        color: #f5f7fa;
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
    }
    .markdown-body {
        max-width: 860px;
        margin: 0 auto;
        padding: 48px 40px 80px;
        line-height: 1.65;
        font-size: 16px;
    }
    h1, h2, h3, h4, h5, h6 {
        color: #ffffff;
        font-weight: 600;
        margin-top: 1.6em;
        margin-bottom: 0.6em;
        line-height: 1.3;
    }
    h1 { font-size: 2.1em; border-bottom: 1px solid #24314f; padding-bottom: 0.3em; }
    h2 { font-size: 1.6em; border-bottom: 1px solid #1c2740; padding-bottom: 0.25em; }
    h3 { font-size: 1.3em; }
    p { margin: 0.9em 0; color: #eef1f7; }
    a { color: #7db4ff; text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { color: #ffffff; }
    em { color: #dbe6ff; }
    code {
        background: #14203a;
        color: #a8d0ff;
        padding: 0.15em 0.4em;
        border-radius: 4px;
        font-family: "SF Mono", Menlo, Consolas, monospace;
        font-size: 0.9em;
    }
    pre {
        background: #0f1830;
        border: 1px solid #1e2a47;
        border-radius: 8px;
        padding: 16px;
        overflow-x: auto;
    }
    pre code { background: none; padding: 0; color: #d7e3ff; }
    blockquote {
        border-left: 4px solid #3a5cbf;
        margin: 1em 0;
        padding: 0.3em 1em;
        color: #b9c6e6;
        background: rgba(58, 92, 191, 0.08);
    }
    ul, ol { padding-left: 1.6em; color: #eef1f7; }
    li { margin: 0.35em 0; }
    hr { border: none; border-top: 1px solid #24314f; margin: 2.2em 0; }
    table { border-collapse: collapse; width: 100%; margin: 1.2em 0; }
    th, td { border: 1px solid #24314f; padding: 8px 12px; text-align: left; }
    th { background: #14203a; color: #ffffff; }
    img { max-width: 100%; border-radius: 6px; }
    ::selection { background: #3a5cbf; color: #ffffff; }
    """
}
