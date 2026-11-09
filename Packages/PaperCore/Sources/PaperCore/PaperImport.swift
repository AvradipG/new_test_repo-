import Foundation

/// Bringing a paper file into Manuscript Studio, and a tracker built from the paper's own headings.
public enum PaperImport {
    public struct Heading: Equatable, Sendable {
        public var level: Int
        public var text: String
        public init(level: Int, text: String) { self.level = level; self.text = text }
    }

    /// Manuscript Studio's stored format for a file extension (nil when the file needs converting first).
    public static func format(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "tex", "latex": return "latex"
        case "md", "markdown", "txt": return "markdown"
        case "html", "htm": return "html"
        default: return nil
        }
    }

    /// A Firestore-safe id from the title (letters, digits, dashes), with a short suffix so it is unique.
    public static func projectID(title: String, suffix: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US")).lowercased()
        var slug = folded.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "paper" }
        let base = String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let s = suffix.lowercased().filter { $0.isLetter || $0.isNumber }
        return s.isEmpty ? base : "\(base)-\(s.prefix(6))"
    }

    public static func title(latex: String) -> String? {
        guard let r = latex.range(of: #"\\title\s*(\[[^\]]*\])?\s*\{"#, options: .regularExpression) else { return nil }
        return balanced(latex, from: r.upperBound).map { cleanTeX($0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func title(html: String) -> String? {
        for tag in ["h1", "title"] {
            if let r = html.range(of: "<\(tag)[^>]*>(.*?)</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                let inner = html[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let t = ManuscriptHTML.plainText(String(inner))
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    public static func title(markdown: String) -> String? {
        for line in markdown.split(separator: "\n") where line.hasPrefix("# ") {
            return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func headings(latex: String) -> [Heading] {
        var out: [Heading] = []
        guard let re = try? NSRegularExpression(pattern: #"\\(section|subsection)\*?\s*\{"#) else { return out }
        let ns = latex as NSString
        for m in re.matches(in: latex, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1))
            let start = latex.index(latex.startIndex, offsetBy: m.range.location + m.range.length)
            if let body = balanced(latex, from: start) {
                let t = cleanTeX(body)
                if !t.isEmpty { out.append(Heading(level: kind == "section" ? 1 : 2, text: t)) }
            }
        }
        return out
    }

    public static func headings(html: String) -> [Heading] {
        guard let re = try? NSRegularExpression(pattern: "<h([1-3])[^>]*>(.*?)</h\\1>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let all = re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m -> Heading? in
            let level = Int(ns.substring(with: m.range(at: 1))) ?? 2
            let t = ManuscriptHTML.plainText(ns.substring(with: m.range(at: 2)))
            return t.isEmpty ? nil : Heading(level: level, text: t)
        }
        // A single h1 is the title: sections are then the h2s.
        let h1 = all.filter { $0.level == 1 }.count
        if h1 <= 1 && all.contains(where: { $0.level == 2 }) {
            return all.filter { $0.level > 1 }.map { Heading(level: $0.level - 1, text: $0.text) }
        }
        return all.filter { $0.level <= 2 }
    }

    public static func headings(markdown: String) -> [Heading] {
        var out: [Heading] = []
        for line in markdown.split(separator: "\n") {
            if line.hasPrefix("## ") { out.append(Heading(level: 1, text: line.dropFirst(3).trimmingCharacters(in: .whitespaces))) }
            else if line.hasPrefix("### ") { out.append(Heading(level: 2, text: line.dropFirst(4).trimmingCharacters(in: .whitespaces))) }
        }
        return out
    }

    public static func equationCount(latex: String) -> Int {
        let envs = ["equation", "align", "gather", "multline"]
        return envs.reduce(0) { n, e in n + ManuscriptHTML.occurrences(of: "\\begin{\(e)}", in: latex).count }
    }

    /// The tracker: one section per top-level heading, its subsections as steps groups, each with writing checks.
    public static func tracker(id: String, title: String, headings: [Heading], equations: Int, manuscriptURL: String?, now: Date = Date()) -> Paper {
        let sections = headings.filter { $0.level == 1 }
        guard !sections.isEmpty else { return Templates.article(title: title, id: id, manuscriptURL: manuscriptURL, now: now) }
        var p = Paper(id: id, title: title, subtitle: equations > 0 ? "\(sections.count) sections · \(equations) numbered equations" : "\(sections.count) sections",
                      manuscriptURL: manuscriptURL, now: now)
        var order = 0.0
        func add(_ nid: String, _ parent: String?, _ t: String) {
            order += 1
            p.nodes.append(Node(id: nid, parentID: parent, title: t, order: order, updatedAt: now))
        }
        let checks = ["Draft complete", "Science checked", "Language polished"]
        var sectionIndex = 0
        var currentSection: String?
        var subIndex = 0
        for h in headings {
            if h.level == 1 {
                sectionIndex += 1
                subIndex = 0
                let sid = "\(id)/s\(sectionIndex)"
                currentSection = sid
                add(sid, nil, h.text)
                add("\(sid)/text", sid, "Text")
                for (k, c) in checks.enumerated() { add("\(sid)/text/\(k + 1)", "\(sid)/text", c) }
            } else if let sid = currentSection {
                subIndex += 1
                add("\(sid)/sub\(subIndex)", sid, h.text)
            }
        }
        if equations > 0 {
            add("\(id)/equations", nil, "Equations")
            for (k, c) in ["Notation consistent", "Every equation numbered and referenced", "Derivations checked"].enumerated() {
                add("\(id)/equations/\(k + 1)", "\(id)/equations", c)
            }
        }
        add("\(id)/submission", nil, "Submission")
        for (k, c) in ["Journal chosen", "Formatted to guidelines", "Final PDF read end to end", "Cover letter", "Submitted"].enumerated() {
            add("\(id)/submission/\(k + 1)", "\(id)/submission", c)
        }
        return p
    }

    // MARK: TeX helpers

    /// The text inside a {...} group that starts right after `from` (the opening brace already consumed).
    static func balanced(_ s: String, from: String.Index) -> String? {
        var depth = 1
        var i = from
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" { i = s.index(after: i); if i < s.endIndex { i = s.index(after: i) }; continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { return String(s[from..<i]) } }
            i = s.index(after: i)
        }
        return nil
    }

    static func cleanTeX(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\\\\"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\(textbf|textit|emph|mathrm|text)\s*\{([^{}]*)\}"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\thanks\s*\{[^{}]*\}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "~", with: " ").replacingOccurrences(of: "--", with: "–")
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
