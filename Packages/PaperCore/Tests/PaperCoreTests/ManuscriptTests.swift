import XCTest
@testable import PaperCore

final class ManuscriptTests: XCTestCase {
    let html = """
    <h2>3. Phase-invariant polarization descriptors</h2><p>The pair is invariant under any nonzero complex rescaling.</p>\
    <div data-equation="true" data-latex="\\mathbf Q\\mathbf s=\\mathbf 0" data-number="18" id="eq:identities" class="writer-equation">\\mathbf Q\\mathbf s=\\mathbf 0</div>\
    <p>Rock &amp; roll appears once. The response tensor is smoother.</p><p>The response tensor is smoother again.</p>
    """

    func testConfigParsing() {
        let js = """
        window.GA_FIREBASE_CONFIG = {
          apiKey: "AIzaTest-123",
          authDomain: 'manuscript.example.app', "projectId": "project-ed65",
          storageBucket: "bucket.appspot.com", appId: "1:2:web:3"
        };
        """
        let c = FirebaseWebConfig.parse(js: js)
        XCTAssertEqual(c, FirebaseWebConfig(apiKey: "AIzaTest-123", authDomain: "manuscript.example.app",
                                             projectId: "project-ed65", storageBucket: "bucket.appspot.com"))
        XCTAssertNil(FirebaseWebConfig.parse(js: "window.GA_FIREBASE_CONFIG = { apiKey: \"\", projectId: \"\" };"))
        // The live /write/firebase-config.js is one line of JSON with quoted keys.
        let live = #"window.GA_FIREBASE_CONFIG={"projectId":"project-ed65bb90-aac3-42cd-b77","appId":"1:181489801873:web:0","apiKey":"AIzaXYZ","authDomain":"project-ed65bb90-aac3-42cd-b77.firebaseapp.com","storageBucket":"project-ed65bb90-aac3-42cd-b77.firebasestorage.app"};"#
        XCTAssertEqual(FirebaseWebConfig.parse(js: live)?.apiKey, "AIzaXYZ")
        XCTAssertEqual(FirebaseWebConfig.parse(js: live)?.storageBucket, "project-ed65bb90-aac3-42cd-b77.firebasestorage.app")
        XCTAssertNil(FirebaseWebConfig.parse(js: "<!doctype html><html><title>Manuscript Studio</title>"), "the root rewrite is HTML, not config")
        XCTAssertTrue(FirebaseWebConfig.configURLs[0].absoluteString.hasSuffix("/write/firebase-config.js"))
        XCTAssertEqual(FirebaseWebConfig.manuscriptURL(paper: "green-christoffel-writing").absoluteString,
                       "https://manuscript-studio-181489801873.web.app/write/?paper=green-christoffel-writing")
    }

    func testFirestoreValuesRoundTrip() {
        let input: [String: Any] = ["text": "<p>x</p>", "revision": 4, "ok": true, "ratio": 0.5,
                                    "uids": ["a", "b"], "nested": ["k": "v"], "when": FirestoreValue.ServerTime()]
        let fields = FirestoreValue.fields(input)
        XCTAssertNil(fields["when"], "server times become field transforms instead")
        XCTAssertEqual((fields["revision"] as? [String: Any])?["integerValue"] as? String, "4")
        let back = FirestoreValue.object(fields)
        XCTAssertEqual(back["text"] as? String, "<p>x</p>")
        XCTAssertEqual(back["revision"] as? Int, 4)
        XCTAssertEqual(back["ok"] as? Bool, true)
        XCTAssertEqual(back["ratio"] as? Double, 0.5)
        XCTAssertEqual(back["uids"] as? [String], ["a", "b"])
        XCTAssertEqual((back["nested"] as? [String: Any])?["k"] as? String, "v")
    }

    func testExactEditsMustBeUnique() throws {
        let out = try ManuscriptHTML.apply(html, edits: [TextEdit(find: "nonzero complex rescaling", replace: "nonzero complex rescaling of the vector")])
        XCTAssertTrue(out.contains("rescaling of the vector."))
        XCTAssertThrowsError(try ManuscriptHTML.apply(html, edits: [TextEdit(find: "The response tensor is smoother", replace: "x")])) {
            XCTAssertEqual($0 as? ManuscriptHTML.Failure, .notUnique("The response tensor is smoother", 2))
        }
        XCTAssertThrowsError(try ManuscriptHTML.apply(html, edits: [TextEdit(find: "absent text", replace: "x")]))
        // Equation edit: both copies of the LaTeX change in one replacement.
        let eq = try ManuscriptHTML.apply(html, edits: [TextEdit(
            find: "data-latex=\"\\mathbf Q\\mathbf s=\\mathbf 0\" data-number=\"18\" id=\"eq:identities\" class=\"writer-equation\">\\mathbf Q\\mathbf s=\\mathbf 0</div>",
            replace: "data-latex=\"\\mathbf Q\\,\\mathbf s=\\mathbf 0\" data-number=\"18\" id=\"eq:identities\" class=\"writer-equation\">\\mathbf Q\\,\\mathbf s=\\mathbf 0</div>")])
        XCTAssertTrue(eq.contains("\\mathbf Q\\,\\mathbf s"))
    }

    func testHighlightAndCommentAnchors() throws {
        let h = try ManuscriptHTML.highlight(html, quote: "invariant under any nonzero")
        XCTAssertTrue(h.contains("<mark data-color=\"#fff1a6\" style=\"background-color: #fff1a6; color: inherit\">invariant under any nonzero</mark>"))
        let c = try ManuscriptHTML.anchorComment(html, quote: "Rock & roll appears once", commentID: "c-1")
        XCTAssertTrue(c.contains("<span data-comment-id=\"c-1\" class=\"comment-anchor\">Rock &amp; roll appears once</span>"))
        XCTAssertThrowsError(try ManuscriptHTML.highlight(html, quote: "The response tensor is smoother"))
        XCTAssertThrowsError(try ManuscriptHTML.highlight(html, quote: "writer-equation"), "text inside markup is refused")
        XCTAssertThrowsError(try ManuscriptHTML.highlight(html, quote: "descriptors The pair"), "crossing two blocks is refused")
        XCTAssertThrowsError(try ManuscriptHTML.highlight(html, quote: "   "))
    }

    func testPlainTextAndWords() {
        XCTAssertEqual(ManuscriptHTML.plainText("<p>A &amp; B</p><p>C&nbsp;D</p>"), "A & B C D")
        XCTAssertEqual(ManuscriptHTML.wordCount("<p>one two</p><p>three</p>"), 3)
    }

    func testAssistantResultParsingAndTrackerMapping() throws {
        let json = """
        ```json
        {"reply": "Two fixes.", "edits": [{"find": "a", "replace": "b", "why": "typo"}],
         "comments": [{"quote": "q", "note": "n"}], "highlights": [], "replies": [{"comment_id": "c1", "text": "Done"}],
         "comment_status": [{"comment_id": "c1", "status": "resolved"}],
         "tracker": [{"op": "set_status", "target": "Cover letter", "status": "done", "title": "", "parent": "", "text": ""}]}
        ```
        """
        let r = try XCTUnwrap(AssistantResult.parse(json))
        XCTAssertEqual(r.reply, "Two fixes.")
        XCTAssertEqual(r.edits, [TextEdit(find: "a", replace: "b", why: "typo")])
        XCTAssertEqual(r.replies.first?.commentId, "c1")
        XCTAssertTrue(r.hasChanges)
        let op = r.tracker[0].inboxOp
        XCTAssertEqual(op.match, "Cover letter")
        XCTAssertNil(op.parentMatch)
        var p = Templates.greenChristoffel()
        Inbox.apply(InboxFile(ops: [op]), to: &p)
        XCTAssertEqual(Tree(p).find("Cover letter")?.status, .done)
        XCTAssertFalse(AssistantResult.parse("{\"reply\": \"Just an answer\"}")!.hasChanges)
        XCTAssertNil(AssistantResult.parse("not json"))
    }

    func testSchemaIsValidJSONWithEveryPropertyRequired() throws {
        let s = AssistantPrompt.schemaObject
        let props = try XCTUnwrap(s["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), Set(s["required"] as? [String] ?? []))
        XCTAssertEqual(s["additionalProperties"] as? Bool, false)
    }

    func testClaudeStream() {
        var s = ClaudeStream()
        for line in [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"cache_read_input_tokens":1200}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"reply\":"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\"ok\"}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            "",
        ] { s.feed(line: line) }
        XCTAssertEqual(s.text, "{\"reply\":\"ok\"}")
        XCTAssertEqual(s.stopReason, "end_turn")
        XCTAssertEqual(s.cacheRead, 1200)
        var e = ClaudeStream()
        e.feed(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        XCTAssertEqual(e.errorMessage, "Overloaded")
    }

    func testFirebaseUserRecordShape() {
        let r = FirebaseUserRecord.json(uid: "u1", email: "a@b.c", displayName: "Avra", photoURL: nil, googleSub: "123",
                                        idToken: "id", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 100), apiKey: "K")
        XCTAssertEqual(r["uid"] as? String, "u1")
        XCTAssertEqual(r["emailVerified"] as? Bool, true)
        XCTAssertEqual(r["isAnonymous"] as? Bool, false)
        let sts = r["stsTokenManager"] as? [String: Any]
        XCTAssertEqual(sts?["refreshToken"] as? String, "rt")
        XCTAssertEqual(sts?["expirationTime"] as? Int, 100_000)
        XCTAssertEqual(FirebaseUserRecord.storageKey(apiKey: "K"), "firebase:authUser:K:[DEFAULT]")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
    }
}

final class AIWireTests: XCTestCase {
    func testClaudeBodyCachesTheManuscriptAndUsesHighEffort() throws {
        let b = ClaudeWire.body(system: "sys", cached: "PAPER", context: "Q", schema: AssistantPrompt.schemaObject)
        XCTAssertEqual(b["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(b["stream"] as? Bool, true)
        XCTAssertEqual(b["fallbacks"] as? String, "default")
        XCTAssertNil(b["temperature"])
        XCTAssertNil(b["thinking"], "Opus 5.5 always thinks; effort is the control")
        let oc = try XCTUnwrap(b["output_config"] as? [String: Any])
        XCTAssertEqual(oc["effort"] as? String, "high")
        XCTAssertEqual((oc["format"] as? [String: Any])?["type"] as? String, "json_schema")
        let content = try XCTUnwrap(((b["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "PAPER")
        XCTAssertNotNil(content[0]["cache_control"])
        XCTAssertNil(content[1]["cache_control"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(b))
        XCTAssertEqual(ClaudeWire.headers(apiKey: "k")["anthropic-version"], "2026-10-21")
    }

    func testClaudeFinish() {
        var s = ClaudeStream()
        s.feed(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        XCTAssertThrowsError(try ClaudeWire.finish(s)) { XCTAssertEqual($0 as? AIFailure, .refused) }
        XCTAssertEqual(ClaudeWire.failure(status: 401, body: Data()), .badKey(.claude))
    }

    func testOpenAIBodyAndText() throws {
        let b = OpenAIWire.body(model: "astra", system: "sys", cached: "PAPER", context: "Q", schema: AssistantPrompt.schemaObject)
        XCTAssertEqual((b["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual(((b["text"] as? [String: Any])?["format"] as? [String: Any])?["strict"] as? Bool, true)
        XCTAssertNil(OpenAIWire.body(model: "m", system: "", cached: "", context: "", effort: nil, schema: [:])["reasoning"])
        let ok = #"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"{\"reply\":\"hi\"}"}]}]}"#
        XCTAssertEqual(try OpenAIWire.text(status: 200, data: Data(ok.utf8)), "{\"reply\":\"hi\"}")
        XCTAssertThrowsError(try OpenAIWire.text(status: 429, data: Data())) { XCTAssertEqual($0 as? AIFailure, .rateLimited) }
    }

    func testModelPickPrefersAstra() {
        func list(_ ids: [(String, Int)]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0.0, "created": $0.1] }])
        }
        XCTAssertEqual(OpenAIWire.pickModel(fromModelsList: list([("gpt-6", 300), ("astra", 100), ("astra-mini", 400)])), "astra")
        XCTAssertEqual(OpenAIWire.pickModel(fromModelsList: list([("gpt-6", 300), ("gpt-astra-2", 200), ("gpt-astra-1", 100)])), "gpt-astra-2")
        XCTAssertEqual(OpenAIWire.pickModel(fromModelsList: list([("gpt-5", 100), ("gpt-6", 300), ("gpt-6-mini", 400), ("gpt-6-2026-01-01", 500)])), "gpt-6")
        XCTAssertNil(OpenAIWire.pickModel(fromModelsList: Data("{}".utf8)))
    }
}

final class PaperImportTests: XCTestCase {
    let tex = #"""
    \documentclass{article}
    \title{Complex Wave Propagation in Anisotropic Viscoelastic Solids: \\ A Geometric-Algebra Perspective in GA(3,0)\thanks{Draft}}
    \begin{document}\maketitle
    \section{Introduction}
    Text.
    \section{Geometric algebra of \emph{Euclidean} space}
    \subsection{The geometric product}
    \begin{equation} ab = a\cdot b + a\wedge b \end{equation}
    \begin{align} x &= 1 \end{align}
    \section*{Acknowledgements}
    \end{document}
    """#

    func testFormatsAndIDs() {
        XCTAssertEqual(PaperImport.format(forExtension: "TEX"), "latex")
        XCTAssertEqual(PaperImport.format(forExtension: "md"), "markdown")
        XCTAssertEqual(PaperImport.format(forExtension: "html"), "html")
        XCTAssertNil(PaperImport.format(forExtension: "docx"))
        XCTAssertEqual(PaperImport.projectID(title: "Complex Wave Propagation: A Geometric-Algebra Perspective in GA(3,0)", suffix: "A1b2c3d4"),
                       "complex-wave-propagation-a-geometric-algebra-perspective-in-a1b2c3")
        XCTAssertEqual(PaperImport.projectID(title: "Červený & Pšenčík", suffix: ""), "cerveny-psencik")
        XCTAssertEqual(PaperImport.projectID(title: "!!!", suffix: "x"), "paper-x")
    }

    func testLatexTitleHeadingsAndEquations() {
        XCTAssertEqual(PaperImport.title(latex: tex), "Complex Wave Propagation in Anisotropic Viscoelastic Solids: A Geometric-Algebra Perspective in GA(3,0)")
        XCTAssertEqual(PaperImport.headings(latex: tex).map(\.text), ["Introduction", "Geometric algebra of Euclidean space", "The geometric product", "Acknowledgements"])
        XCTAssertEqual(PaperImport.headings(latex: tex).map(\.level), [1, 1, 2, 1])
        XCTAssertEqual(PaperImport.equationCount(latex: tex), 2)
    }

    func testHTMLAndMarkdownHeadings() {
        let html = "<h1>My Paper</h1><p>x</p><h2>1. Intro</h2><h3>1.1 Aim</h3><h2>2. Theory</h2>"
        XCTAssertEqual(PaperImport.title(html: html), "My Paper")
        XCTAssertEqual(PaperImport.headings(html: html), [.init(level: 1, text: "1. Intro"), .init(level: 2, text: "1.1 Aim"), .init(level: 1, text: "2. Theory")])
        XCTAssertEqual(PaperImport.title(markdown: "# T\n## A\n### B"), "T")
        XCTAssertEqual(PaperImport.headings(markdown: "# T\n## A\n### B").map(\.level), [1, 2])
    }

    func testTrackerFromHeadings() {
        let p = PaperImport.tracker(id: "ga", title: "GA", headings: PaperImport.headings(latex: tex), equations: 2, manuscriptURL: nil)
        let tree = Tree(p)
        XCTAssertEqual(tree.children(of: nil).map(\.title), ["Introduction", "Geometric algebra of Euclidean space", "Acknowledgements", "Equations", "Submission"])
        XCTAssertEqual(tree.children(of: "ga/s2").map(\.title), ["Text", "The geometric product"])
        XCTAssertEqual(Set(p.nodes.map(\.id)).count, p.nodes.count)
        XCTAssertEqual(PaperImport.tracker(id: "x", title: "X", headings: [], equations: 0, manuscriptURL: nil).nodes.count,
                       Templates.article(title: "X", id: "x").nodes.count)
    }
}

final class EmbeddedImageTests: XCTestCase {
    func testDataImagesBecomePlaceholders() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()
        let html = "<p>a</p><img src=\"data:image/png;base64,\(png)\" alt=\"Figure 1\"><img src=\"asset://keep\"><img src=\"data:image/jpeg;base64,\(png)\">"
        let (out, images) = ManuscriptHTML.extractEmbeddedImages(html)
        XCTAssertEqual(images.map(\.placeholder), ["asset://pending-1", "asset://pending-2"])
        XCTAssertEqual(images.map(\.mime), ["image/png", "image/jpeg"])
        XCTAssertEqual(images[0].data, Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        XCTAssertEqual(out, "<p>a</p><img src=\"asset://pending-1\" alt=\"Figure 1\"><img src=\"asset://keep\"><img src=\"asset://pending-2\">")
        XCTAssertEqual(ManuscriptHTML.extractEmbeddedImages("<p>none</p>").images.count, 0)
    }
}

final class ChatWireTests: XCTestCase {
    func testClaudeChatBodyCarriesPicturesAndHighEffort() throws {
        let b = ChatWire.claudeBody(context: "diag", message: "What broke?", images: [Data([1, 2, 3])])
        XCTAssertEqual(b["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual((b["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil((b["output_config"] as? [String: Any])?["format"], "chat answers are plain text")
        let content = try XCTUnwrap(((b["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image", "text"])
        XCTAssertEqual(((content[1]["source"] as? [String: Any])?["data"]) as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertTrue(JSONSerialization.isValidJSONObject(b))
    }

    func testOpenAIChatBody() throws {
        let b = ChatWire.openAIBody(model: "astra", context: "", message: "hi", images: [Data([9])])
        let content = try XCTUnwrap(((b["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["input_image", "input_text"])
        XCTAssertNil(b["text"], "no JSON schema for chat")
        XCTAssertEqual((b["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    }

    func testTranscriptAndAppRequest() {
        let turns = [ChatWire.Turn(fromUser: true, text: "Sign-in fails"), ChatWire.Turn(fromUser: false, text: "Safelist the client ID.")]
        let t = ChatWire.transcript(turns, context: "App 1.3")
        XCTAssertTrue(t.contains("CONTEXT FROM THE APP:\nApp 1.3"))
        XCTAssertTrue(t.contains("AVRA: Sign-in fails\nASSISTANT: Safelist the client ID."))
        let r = ChatWire.appRequest(summary: "Make sign-in work", conversation: turns, diagnostics: "x", pictures: 2,
                                    date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(r.contains("## Request\n\nMake sign-in work"))
        XCTAssertTrue(r.contains("picture-1.jpg"))
        XCTAssertTrue(r.contains("1970-01-01T00:00:00Z"))
    }
}
