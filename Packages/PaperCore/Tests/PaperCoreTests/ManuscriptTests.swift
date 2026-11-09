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
