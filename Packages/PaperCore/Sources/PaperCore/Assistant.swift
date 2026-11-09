import Foundation

/// What Claude or ChatGPT sends back when asked about the open paper. Every field is always present (empty when
/// unused) so the same strict JSON schema works for both services.
public struct AssistantResult: Codable, Equatable, Sendable {
    public struct Comment: Codable, Equatable, Sendable {
        public var quote: String
        public var note: String
        public init(quote: String, note: String) { self.quote = quote; self.note = note }
    }

    public struct Highlight: Codable, Equatable, Sendable {
        public var quote: String
        public init(quote: String) { self.quote = quote }
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var commentId: String
        public var text: String
        public init(commentId: String, text: String) { self.commentId = commentId; self.text = text }
        enum CodingKeys: String, CodingKey { case commentId = "comment_id", text }
    }

    public struct CommentStatus: Codable, Equatable, Sendable {
        public var commentId: String
        public var status: String
        public init(commentId: String, status: String) { self.commentId = commentId; self.status = status }
        enum CodingKeys: String, CodingKey { case commentId = "comment_id", status }
    }

    public struct TrackerOp: Codable, Equatable, Sendable {
        public var op: String
        public var target: String
        public var status: String
        public var title: String
        public var parent: String
        public var text: String

        public init(op: String, target: String = "", status: String = "", title: String = "", parent: String = "", text: String = "") {
            self.op = op; self.target = target; self.status = status; self.title = title; self.parent = parent; self.text = text
        }

        /// As a Claude-inbox op, so the tracker applies it exactly like a file dropped into claude-inbox.
        public var inboxOp: InboxOp {
            func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
            return InboxOp(op: op, match: opt(target), parentMatch: opt(parent), title: opt(title), status: opt(status), text: opt(text))
        }
    }

    public var reply: String
    public var edits: [TextEdit]
    public var comments: [Comment]
    public var highlights: [Highlight]
    public var replies: [Reply]
    public var commentStatus: [CommentStatus]
    public var tracker: [TrackerOp]

    public init(reply: String, edits: [TextEdit] = [], comments: [Comment] = [], highlights: [Highlight] = [],
                replies: [Reply] = [], commentStatus: [CommentStatus] = [], tracker: [TrackerOp] = []) {
        self.reply = reply; self.edits = edits; self.comments = comments; self.highlights = highlights
        self.replies = replies; self.commentStatus = commentStatus; self.tracker = tracker
    }

    enum CodingKeys: String, CodingKey {
        case reply, edits, comments, highlights, replies, commentStatus = "comment_status", tracker
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        edits = try c.decodeIfPresent([TextEdit].self, forKey: .edits) ?? []
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        replies = try c.decodeIfPresent([Reply].self, forKey: .replies) ?? []
        commentStatus = try c.decodeIfPresent([CommentStatus].self, forKey: .commentStatus) ?? []
        tracker = try c.decodeIfPresent([TrackerOp].self, forKey: .tracker) ?? []
    }

    /// Whether anything would change (beyond the chat answer).
    public var hasChanges: Bool {
        !(edits.isEmpty && comments.isEmpty && highlights.isEmpty && replies.isEmpty && commentStatus.isEmpty && tracker.isEmpty)
    }

    public static func parse(_ text: String) -> AssistantResult? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        }
        return try? JSONDecoder().decode(AssistantResult.self, from: Data(t.utf8))
    }
}

/// A comment of the paper, as the assistant sees it.
public struct PaperComment: Codable, Equatable, Sendable {
    public var id: String
    public var author: String
    public var quote: String
    public var note: String
    public var status: String
    public var replies: [String]

    public init(id: String, author: String, quote: String, note: String, status: String, replies: [String]) {
        self.id = id; self.author = author; self.quote = quote; self.note = note; self.status = status; self.replies = replies
    }
}

/// The instructions and the strict output schema shared by Claude and ChatGPT.
public enum AssistantPrompt {
    public static let system = """
    You are the writing partner inside Paper Quest, working on Avra's scientific manuscript in Manuscript Studio.
    Talk the way a careful co-author would: precise, brief, and honest about uncertainty. Never invent results,
    numbers, references or citations.

    The manuscript is a TipTap HTML document. Its markup:
    - Paragraphs <p>, headings <h1>-<h3>, lists, tables, <strong>, <em>, <u>, <s>, <sub>, <sup>.
    - Display equation: <div data-equation="true" data-latex="LATEX" data-number="N" id="LABEL" class="writer-equation">LATEX</div>
      (the LaTeX appears twice: in data-latex, HTML-escaped, and as the text). Inline: <span data-inline-equation="true" data-latex="LATEX">LATEX</span>.
    - Figures: <img src="asset://ID" alt="...">. Never change asset:// sources.
    - Highlight: <mark data-color="#fff1a6" style="background-color: #fff1a6; color: inherit">text</mark>.
    - Comment anchor: <span data-comment-id="ID" class="comment-anchor">text</span>. Never remove anchors of open comments.

    How to change things (only when Avra asks for a change; otherwise answer in "reply" and leave every list empty):
    - edits: exact replacements in the HTML. "find" must be copied character for character from the HTML and
      occur exactly once; include enough surrounding text to make it unique, but keep it short. "replace" is the
      new HTML. For an equation, change both data-latex and the text. Keep markup valid. "why" is one short line.
    - comments: anchored notes. "quote" is visible text from ONE paragraph (no markup inside), unique in the paper.
    - highlights: "quote" as for comments; it gets the yellow highlight.
    - replies / comment_status: answer or resolve ("resolved") / reopen ("open") existing comments by their id.
    - tracker: Paper Quest checklist ops ("set_status" with status todo/in_progress/done, "add" with title and
      parent, "note" with text, "rename" with title). "target" is a tracker id or title. Tick items "done" only
      when Avra says the item is finished to their satisfaction.
    Nothing is applied until Avra reviews and approves your proposal, so propose complete, correct changes.
    In "reply", say what you propose and why, in plain language. Keep math in LaTeX.
    """

    /// JSON Schema for the answer (strict: every property required, no extras).
    public static let schema = """
    {"type":"object","additionalProperties":false,
     "required":["reply","edits","comments","highlights","replies","comment_status","tracker"],
     "properties":{
      "reply":{"type":"string"},
      "edits":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["find","replace","why"],
        "properties":{"find":{"type":"string"},"replace":{"type":"string"},"why":{"type":"string"}}}},
      "comments":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["quote","note"],
        "properties":{"quote":{"type":"string"},"note":{"type":"string"}}}},
      "highlights":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["quote"],
        "properties":{"quote":{"type":"string"}}}},
      "replies":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["comment_id","text"],
        "properties":{"comment_id":{"type":"string"},"text":{"type":"string"}}}},
      "comment_status":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["comment_id","status"],
        "properties":{"comment_id":{"type":"string"},"status":{"type":"string","enum":["open","resolved"]}}}},
      "tracker":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["op","target","status","title","parent","text"],
        "properties":{"op":{"type":"string","enum":["set_status","add","note","rename"]},"target":{"type":"string"},
          "status":{"type":"string"},"title":{"type":"string"},"parent":{"type":"string"},"text":{"type":"string"}}}}
     }}
    """

    public static var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any] ?? [:]
    }

    /// The paper itself: stable between turns, so Claude can cache it.
    public static func manuscriptBlock(title: String, revision: Int, html: String) -> String {
        "MANUSCRIPT “\(title)” (revision \(revision), HTML):\n\(html)"
    }

    /// Comments and the tracker: they change more often, so they follow the cached paper.
    public static func contextBlock(comments: [PaperComment], progress: String?) -> String {
        var s = "COMMENTS (\(comments.count)):\n"
        if comments.isEmpty { s += "(none)\n" }
        for c in comments {
            s += "- id \(c.id) [\(c.status)] \(c.author): \(c.note)"
            if !c.quote.isEmpty { s += " — on “\(c.quote)”" }
            for r in c.replies { s += "\n    reply: \(r)" }
            s += "\n"
        }
        if let progress, !progress.isEmpty { s += "\nPAPER QUEST TRACKER:\n\(progress)" }
        return s
    }
}

/// Claude's streamed answer (server-sent events), read line by line.
public struct ClaudeStream: Sendable {
    public private(set) var text = ""
    public private(set) var stopReason: String?
    public private(set) var errorMessage: String?
    public private(set) var cacheRead = 0
    private var event = ""

    public init() {}

    public mutating func feed(line: String) {
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return
        }
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? event
        switch type {
        case "content_block_delta":
            if let d = obj["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String { text += t }
        case "message_start":
            if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
            }
        case "message_delta":
            if let d = obj["delta"] as? [String: Any], let s = d["stop_reason"] as? String { stopReason = s }
        case "error":
            errorMessage = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "Claude reported an error."
        default:
            break
        }
    }
}
