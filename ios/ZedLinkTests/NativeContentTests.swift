import XCTest
import UIKit
import SwiftUI
@testable import ZedLink

final class SessionActivityTests: XCTestCase {
    func testAuthoritativeAttentionRetryFailureAndUnknown() {
        var thread = NativeThread(id: "fixture", title: "Demo", status: "Unknown", currentTurnID: nil)
        XCTAssertEqual(SessionActivity(thread), .unknown)
        thread = NativeThread(id: "fixture", title: "Demo", status: "Idle", currentTurnID: nil)
        XCTAssertEqual(SessionActivity(thread), .ready)
        thread.failed = true; XCTAssertEqual(SessionActivity(thread), .failed)
        thread = NativeThread(id: "fixture", title: "Demo", status: "Generating", currentTurnID: nil, failed: true)
        XCTAssertEqual(SessionActivity(thread), .generating)
        thread.activity = NativeAgentActivity(phase: "compacting", label: "Compacting context", detail: nil)
        XCTAssertEqual(SessionActivity(thread), .compacting)
        thread.activity = NativeAgentActivity(phase: "running_tool", label: "Running tool", detail: "Search")
        XCTAssertEqual(SessionActivity(thread), .generating)
        thread.activity = NativeAgentActivity(phase: "waiting_for_approval", label: "Waiting for approval", detail: "Terminal")
        XCTAssertEqual(SessionActivity(thread), .approval)
        thread.activity = .ready
        thread.retrying = true; XCTAssertEqual(SessionActivity(thread), .retrying)
        thread.inputCount = 1; XCTAssertEqual(SessionActivity(thread), .input)
        thread.approvalCount = 2; XCTAssertEqual(SessionActivity(thread), .approval)
    }
    @MainActor func testPinsAreScopedAndActivityRequiresObservedChange() {
        let name = "zedlink.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let library = SessionLibrary(defaults: defaults)
        let key = SessionLibrary.key(profile: "a", target: "demo", thread: "id")
        let other = SessionLibrary.key(profile: "b", target: "demo", thread: "id")
        library.toggle(key); XCTAssertTrue(library.pins.contains(key)); XCTAssertFalse(library.pins.contains(other))
        XCTAssertTrue(SessionLibrary(defaults: defaults).pins.contains(key))
        var thread = NativeThread(id: "id", title: "Demo", status: "Idle", currentTurnID: nil)
        library.observe([thread], profile: "a", target: "demo", selected: nil)
        XCTAssertTrue(library.updated.isEmpty)
        thread = NativeThread(id: "id", title: "Demo", status: "Generating", currentTurnID: nil)
        library.observe([thread], profile: "a", target: "demo", selected: nil)
        XCTAssertTrue(library.updated.contains(key)); library.seen(key); XCTAssertTrue(library.updated.isEmpty)
    }

    @MainActor func testRecentlyOpenedKeepsGatewayScopeAndPersistsOrder() {
        let name = "zedlink.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = SessionLibrary.key(profile: "gateway-a", target: "project", thread: "same-thread")
        let other = SessionLibrary.key(profile: "gateway-b", target: "project", thread: "same-thread")
        let library = SessionLibrary(defaults: defaults)
        library.opened(first)
        library.opened(other)
        library.opened(first)
        XCTAssertEqual(library.recent, [first, other])
        XCTAssertEqual(SessionLibrary(defaults: defaults).recent, [first, other])
    }
}

final class InputFormTests: XCTestCase {
    private func field(_ type: String = "string", required: Bool = true, choices: [String] = []) -> NativeElicitationField {
        NativeElicitationField(id: "value", title: "Value", type: type, required: required, choices: choices)
    }
    private func submit(_ field: NativeElicitationField, _ value: String? = nil) throws -> [String: Any] {
        try ElicitationForm.content([field], values: value.map { ["value": $0] } ?? [:], selections: [:])
    }
    func testUntouchedDisplayedChoiceAndDefaultAreSubmitted() throws {
        var choice = field(choices: ["local", "remote"])
        XCTAssertEqual(ElicitationForm.value(choice, values: [:]), "local")
        XCTAssertEqual(try submit(choice)["value"] as? String, "local")
        choice.defaultValue = "remote"
        XCTAssertEqual(try submit(choice)["value"] as? String, "remote")
        XCTAssertThrowsError(try submit(choice, "unadvertised"))
    }
    func testOptionalOmissionAndRequiredFalse() throws {
        XCTAssertTrue(try submit(field(required: false, choices: ["a"])).isEmpty)
        XCTAssertEqual(try submit(field("boolean"))["value"] as? Bool, false)
        XCTAssertTrue(try submit(field("boolean", required: false)).isEmpty)
        XCTAssertThrowsError(try submit(field(), "  "))
    }
    func testNumericTypesAndValidation() throws {
        var number = field("number"); number.minimum = 1; number.maximum = 3
        XCTAssertEqual(try submit(number, "2.5")["value"] as? Double, 2.5)
        for value in ["NaN", "Infinity", "text", "0", "4"] { XCTAssertThrowsError(try submit(number, value)) }
        XCTAssertEqual(try submit(field("integer"), "2")["value"] as? Int, 2)
        XCTAssertThrowsError(try submit(field("integer"), "2.5"))
    }
    func testMultipleChoicesAndArrayDefaults() throws {
        let array = field("array", choices: ["a", "b", "c"])
        XCTAssertEqual(try ElicitationForm.content([array], values: [:], selections: ["value": ["c", "a"]])["value"] as? [String], ["a", "c"])
        var defaults = field("array"); defaults.defaultValue = "[\"b\",\"a\",\"b\"]"
        XCTAssertEqual(ElicitationForm.value(defaults, values: [:]), "b, a, b")
        XCTAssertEqual(try submit(defaults)["value"] as? [String], ["b", "a", "b"])
        XCTAssertThrowsError(try submit(array))
    }
    func testUnicodeLengthAndUnsupportedTypes() throws {
        var text = field(); text.minLength = 1; text.maxLength = 1
        XCTAssertEqual(try submit(text, "😀")["value"] as? String, "😀")
        XCTAssertThrowsError(try submit(text, "ab"))
        XCTAssertThrowsError(try submit(field("object"), "{}"))
    }
}

final class ReviewNavigationTests: XCTestCase {
    func testMatchPositionWrapAndQueryReplacement() {
        var index = ReviewIndex("Alpha\nbeta\nALPHA")
        index.find("alpha")
        XCTAssertEqual(index.matches, [1, 3]); XCTAssertEqual(index.hits, Set([1, 3]))
        XCTAssertEqual(ReviewIndex.nextMatch(0, delta: -1, count: 2), 1)
        XCTAssertEqual(ReviewIndex.nextMatch(1, delta: 1, count: 2), 0)
        index.find("beta"); XCTAssertEqual(index.matches, [2]); XCTAssertEqual(index.hits, [2])
        index.find(""); XCTAssertTrue(index.hits.isEmpty)
        XCTAssertEqual(ReviewIndex.nextMatch(0, delta: -1, count: 0), 0)
    }
    func testDiffSectionsIncludeDeletedFiles() {
        let index = ReviewIndex("diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n+new\ndiff --git a/b.rs b/b.rs\n--- a/b.rs\n+++ /dev/null\n-old")
        XCTAssertEqual(index.sections.map(\.id), [1, 5])
        XCTAssertEqual(index.sections.map(\.title), ["a.rs", "b.rs"])
    }
    func testConnectionGuidanceDoesNotMisclassifyModelErrors() {
        XCTAssertNil(ConnectionHelp.forMessage("Model context length exceeded"))
        XCTAssertEqual(ConnectionHelp.forMessage(GatewayFailure.changedIdentity.localizedDescription)?.action, .connections)
        XCTAssertEqual(ConnectionHelp.forMessage(GatewayFailure.native("INSTANCE_UNAVAILABLE").localizedDescription)?.action, .retry)
    }
}

final class NativeContentTests: XCTestCase {
    @MainActor
    func testProfileStoreKeepsIdentityForTheSameGatewayAddress() {
        let original = ConnectionProfile(name: "Zed", route: .tailscale,
            endpoint: "https://old.example", gatewayID: "FIXTURE-GATEWAY")
        let updated = ProfileStore.profileForSave(ConnectionProfile(name: "Zed renamed", route: .tailscale,
            endpoint: "https://old.example/", gatewayID: "fixture-gateway"),
            among: [original])
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.name, "Zed renamed")
    }

    @MainActor
    func testProfileStoreKeepsAnotherRouteToTheSameGateway() {
        let original = ConnectionProfile(name: "Tailscale", route: .tailscale,
            endpoint: "https://zed.tailnet.example", gatewayID: "FIXTURE-GATEWAY")
        let alternate = ConnectionProfile(name: "Local", route: .local,
            endpoint: "https://zed.lan.example", gatewayID: "fixture-gateway")
        let saved = ProfileStore.profileForSave(alternate, among: [original])
        XCTAssertNotEqual(saved.id, original.id)
        XCTAssertEqual(saved.endpoint, alternate.endpoint)
    }

    func testAssistantSeparatesPublishedReasoningFromAnswer() {
        let entry = NativeEntryPresentation("""
        ## Assistant

        <thinking>
        Inspecting the native thread
        </thinking>

        The answer is ready.
        """, index: 3)

        XCTAssertEqual(entry.kind, .assistant)
        XCTAssertEqual(entry.reasoning, ["Inspecting the native thread"])
        XCTAssertEqual(entry.body, "The answer is ready.")
    }

    func testStreamingReasoningWithoutClosingTagIsVisible() {
        let entry = NativeEntryPresentation("## Assistant\n\n<thinking>\nStill working", index: 0)
        XCTAssertEqual(entry.reasoning, ["Still working"])
        XCTAssertTrue(entry.body.isEmpty)
    }

    func testToolMetadataUsesNativeProjection() {
        let entry = NativeEntryPresentation("""
        **Tool Call: Run tests**
        Status: InProgress

        Terminal:
        ```
        cargo test
        ```
        """, index: 1)

        XCTAssertEqual(entry.kind, .tool)
        XCTAssertEqual(entry.toolName, "Run tests")
        XCTAssertEqual(entry.toolStatus, "InProgress")
    }
}

final class MobileReviewTests: XCTestCase {
    func testUnifiedDiffSeparatesFileHeadersFromChanges() {
        let lines = ReviewLine.lines("diff --git a/demo.rs b/demo.rs\n--- a/demo.rs\n+++ b/demo.rs\n@@ -1 +1 @@\n-old\n+new\n unchanged")
        XCTAssertEqual(lines.map(\.id), Array(1...7))
        XCTAssertTrue(lines.prefix(4).allSatisfy { $0.kind == .header })
        XCTAssertEqual(lines[4].kind, .removed)
        XCTAssertEqual(lines[5].kind, .added)
        XCTAssertEqual(lines[6].kind, .plain)
    }

    func testRestoredUnknownSendContainsIdentityButNoReplayPayload() throws {
        var pending = PendingSend(id: "fixture-request", instanceID: "fixture-instance", epoch: "fixture-epoch", threadID: "fixture-thread", text: "draft")
        pending.contextPaths = ["src/demo.rs"]
        pending.attachments = [PromptAttachment(name: "image.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))]
        let saved = try JSONEncoder().encode(pending)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "instanceID", "epoch", "threadID"]))
        let restored = try JSONDecoder().decode(PendingSend.self, from: saved)
        XCTAssertEqual(restored.id, pending.id)
        XCTAssertNil(restored.text)
        XCTAssertTrue(restored.attachments.isEmpty)
        XCTAssertTrue(restored.contextPaths.isEmpty)
    }

    @MainActor
    func testImagePreparationCreatesBoundedJPEG() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format)
        let image = renderer.image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let data = try XCTUnwrap(promptJPEG(image))
        XCTAssertLessThanOrEqual(data.count, 1024 * 1024)
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 1600)
        XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8])
    }

    func testTextOnlySubmissionDoesNotRequestAttachmentCapability() {
        let pending = PendingSend(id: "fixture-request", instanceID: "fixture-instance", epoch: "fixture-epoch", threadID: "fixture-thread", text: "draft")
        XCTAssertNil(pending.submissionParams["uploads"])
        XCTAssertNil(pending.submissionParams["context_paths"])
        XCTAssertEqual(pending.submissionParams["text"] as? String, "draft")
    }

    func testPendingPayloadDoesNotChangeWhenDraftAttachmentsChange() {
        let image = PromptAttachment(name: "image.jpg", mimeType: "image/jpeg", data: Data([1, 2]))
        var draft = [image]
        let pending = PendingSend(id: "fixture-request", instanceID: "fixture-instance", epoch: "fixture-epoch", threadID: "fixture-thread", text: "draft", contextPaths: ["src/demo.rs"], attachments: draft)
        draft.removeAll()
        XCTAssertEqual(pending.attachments, [image])
        XCTAssertEqual(pending.attachments[0].payload["data"] as? String, "AQI=")
    }
}

final class MarkdownRenderingTests: XCTestCase {
    @MainActor
    func testLightThemeTextAndAccentContrast() {
        let traits = UITraitCollection(userInterfaceStyle: .light)
        func luminance(_ color: Color) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red * alpha + 1 - alpha) + 0.7152 * linear(green * alpha + 1 - alpha) + 0.0722 * linear(blue * alpha + 1 - alpha)
        }
        for color in [ZLTheme.ink, ZLTheme.muted, ZLTheme.focus, ZLTheme.healthy, ZLTheme.warning, ZLTheme.danger] {
            XCTAssertGreaterThanOrEqual(1.05 / (luminance(color) + 0.05), 4.5)
        }
    }

    func testParagraphsAndNestedListMarkersRemainSeparate() {
        XCTAssertEqual(MarkdownDocument.parse("Intro\ncontinued\n\n## List\n- **Bold**\n  - Nested `code`\n1. First\n\nFinal paragraph"), [
            .paragraph("Intro\ncontinued"), .heading(2, "List"), .item("•", 0, "**Bold**"),
            .item("•", 2, "Nested `code`"), .item("1.", 0, "First"), .paragraph("Final paragraph")
        ])
    }
    func testAlignedTablePreservesEmptyAndEscapedCells() {
        XCTAssertEqual(MarkdownDocument.parse("| Feature | Status | Notes |\n| :--- | :---: | ---: |\n| Bullets | ✅ | a\\|b |\n| Files | | `x|y` |"), [
            .table(["Feature", "Status", "Notes"], [["Bullets", "✅", "a|b"], ["Files", "", "`x|y`"]], [.leading, .center, .trailing])
        ])
    }
    func testStreamingFencedCodeStaysLiteral() {
        XCTAssertEqual(MarkdownDocument.parse("```rust\n- literal\n| not a table |"), [.code("rust", "- literal\n| not a table |")])
        XCTAssertEqual(MarkdownDocument.parse("~~~\nhello\n~~~\nAfter"), [.code("", "hello"), .paragraph("After")])
    }
    func testListContinuationAndMalformedTableRemainReadable() {
        XCTAssertEqual(MarkdownDocument.parse("a | b\n-- | nope"), [.paragraph("a | b\n-- | nope")])
        XCTAssertEqual(MarkdownDocument.parse("- long\n  continued\n- next"), [.item("•", 0, "long\ncontinued"), .item("•", 0, "next")])
    }
}

final class NativeAgentErrorTests: XCTestCase {
    func testContextAndConnectionFailuresKeepNativeDetails() {
        for message in ["Input too long (~76332 tokens, max 65536). Shorten your context.", "Connection refused by model server"] {
            let decoded = NativeAgentError(snapshot: ["agent_error": ["kind": "model_error", "title": "An error happened", "message": message, "retrying": false]])
            XCTAssertEqual(decoded?.message, message)
            XCTAssertEqual(decoded?.kind, "model_error")
            XCTAssertEqual(decoded?.retrying, false)
        }
    }
    func testFallbackRetryAndRecovery() {
        XCTAssertNotNil(NativeAgentError(snapshot: ["had_error": true]))
        XCTAssertNil(NativeAgentError(snapshot: ["had_error": false, "agent_error": NSNull()]))
        XCTAssertNil(NativeAgentError(snapshot: ["agent_error": ["title": 42, "message": "invalid"]]))
        XCTAssertEqual(NativeAgentError(snapshot: ["agent_error": ["title": "Retry", "message": "Busy", "retrying": true]])?.retrying, true)
    }
}
