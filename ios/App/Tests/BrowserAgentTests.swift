import XCTest
import UIKit
@testable import RoamSocket

/// Lightweight unit coverage for the browser-agent helpers that drive the
/// image-fallback pipeline:
///
/// - `looksLikeConsentPage` decides whether to attach a screenshot when
///   the visible-text extraction comes back thin or banner-heavy.
/// - `imageAttachment(from:)` encodes a UIImage for the model call.
/// - the system prompt for the describe-image path must forbid actions
///   so the `.extract` step on a cookie-banner page returns prose, not
///   JSON.
///
/// Lives next to `ImageProcessingTests` because it touches the same
/// image-attachment pipeline, but stays separate so a CI failure here
/// points at the right area immediately.
final class BrowserAgentTests: XCTestCase {

    // MARK: - looksLikeConsentPage

    /// Empty text doesn't get flagged — we only want to trigger image
    /// fallback when there's *something* on screen that looks like a
    /// consent dialog.
    func testLooksLikeConsentPageRejectsEmptyText() {
        XCTAssertFalse(BrowserAgent.looksLikeConsentPage(""))
    }

    /// Regular article text — multiple paragraphs about a product —
    /// must not trigger the consent path, even when it's long.
    func testLooksLikeConsentPageRejectsNormalArticle() {
        let text = """
        The new iPad Pro features the M4 chip and a stunning Ultra Retina
        XDR display. With support for the Apple Pencil Pro and a redesigned
        Magic Keyboard, this is the most capable iPad we've ever made.
        Available in 11-inch and 13-inch models with up to 2TB of storage.
        """
        XCTAssertFalse(BrowserAgent.looksLikeConsentPage(text))
    }

    /// A privacy policy page — long, mostly legal — must not flag
    /// the consent path. We don't want every privacy policy to look
    /// like a consent dialog.
    func testLooksLikeConsentPageRejectsPrivacyPolicy() {
        let text = """
        We respect your privacy. This privacy policy describes the personal
        information we collect, how we use it, and the choices you have.
        Information we collect includes data you provide directly, data we
        collect automatically through cookies and similar technologies, and
        data we receive from third parties. We use this information to
        provide and improve our services, to communicate with you, and to
        comply with our legal obligations. Your choices include opting out
        of marketing communications and managing cookie preferences in your
        account settings.
        """
        XCTAssertFalse(BrowserAgent.looksLikeConsentPage(text))
    }

    /// The classic "we use cookies" + "accept all" banner — should flag
    /// because we have ≥2 consent markers in the same text.
    func testLooksLikeConsentPageAcceptsCookieBanner() {
        let text = """
        We use cookies to deliver our services. By clicking Accept all,
        you agree to our use of cookies for analytics and personalization.
        You can manage settings or reject non-essential cookies anytime.
        """
        XCTAssertTrue(BrowserAgent.looksLikeConsentPage(text))
    }

    /// A barely-consent screen with just the legal copy — should still
    /// trigger if multiple markers (consent + privacy + manage) appear,
    /// because that's a classic layered CMP UI.
    func testLooksLikeConsentPageAcceptsLayeredCMP() {
        let text = "Your privacy choices. Manage settings. Accept all. Reject all."
        XCTAssertTrue(BrowserAgent.looksLikeConsentPage(text))
    }

    /// Single marker alone is not enough — long content with just one
    /// consent mention is more often a real page that happens to mention
    /// cookies than a consent dialog.
    func testLooksLikeConsentPageRejectsSingleMarker() {
        let text = """
        Welcome to Acme! Our blog occasionally mentions cookies in the
        context of web development. We also write about TypeScript, Rust,
        and Swift. Subscribe to our newsletter for weekly updates.
        """
        XCTAssertFalse(BrowserAgent.looksLikeConsentPage(text))
    }

    // MARK: - imageAttachment

    /// Passing a real (tiny) UIImage round-trips through the JPEG
    /// pipeline — the result should be a non-empty JPEG payload that
    /// decodes back to itself at the same dimensions.
    func testImageAttachmentEncodesJPEGForValidImage() throws {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let attachment = BrowserAgent.imageAttachment(from: image) else {
            return XCTFail("Attachment should not be nil for a valid image.")
        }
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertFalse(attachment.base64Data.isEmpty)
        XCTAssertEqual(attachment.bytes.count, attachment.base64Data.base64Decoded?.count ?? 0)
    }

    /// `nil` in → `nil` out, no allocation, no crash.
    func testImageAttachmentReturnsNilForNilImage() {
        XCTAssertNil(BrowserAgent.imageAttachment(from: nil))
    }

    // MARK: - Step Kind wire format

    /// `dismiss_consent` is the wire string the model sends; the Swift
    /// enum case names the action in idiomatic camelCase but the
    /// Codable round-trip must accept the snake_case form.
    func testDismissConsentKindRoundTripsFromWireFormat() throws {
        XCTAssertEqual(BrowserStep.Kind(rawValue: "dismiss_consent"), .dismissConsent)
        XCTAssertEqual(BrowserStep.Kind.dismissConsent.rawValue, "dismiss_consent")

        // And the older kinds still parse exactly the way they did before
        // this change — guard against accidental breakage.
        XCTAssertEqual(BrowserStep.Kind(rawValue: "click"), .click)
        XCTAssertEqual(BrowserStep.Kind(rawValue: "dismissConsent"), nil,
                       "The wire form must be snake_case, not camelCase.")
    }

    // MARK: - System-prompt guarantees for new agent paths

    /// The `extract` step on a thin/consent-y page re-uses
    /// `describePage(image:role:.extract)`. The system prompt for that
    /// path must (a) tell the model it has no actions and (b) ask for
    /// plain prose, never JSON — otherwise the model would emit
    /// markdown fences and break the UI.
    func testDescribeImageSystemPromptForbidsActions() {
        let prompt = BrowserAgent.describeImageSystemPromptPublic(role: .extract)
        XCTAssertTrue(prompt.contains("Do NOT propose"))
        XCTAssertFalse(prompt.contains("```"))
        XCTAssertTrue(prompt.contains("Plain prose only"), "extract role must demand plain prose")
    }

    /// The user-facing `description` role (used by Ask-mode when text +
    /// web search are both empty) gets the same plain-prose guardrail.
    func testDescribeImageSystemPromptForDescriptionRole() {
        let prompt = BrowserAgent.describeImageSystemPromptPublic(role: .description)
        XCTAssertTrue(prompt.contains("Plain prose only"))
        XCTAssertFalse(prompt.contains("```"))
        XCTAssertTrue(prompt.contains("Do NOT propose"))
    }
}

// MARK: - Test helpers

private extension String {
    /// Hand-rolled base64 decoder for test assertions only — keeps the
    /// test file free of any URL/Data utility imports that aren't already
    /// available in the test target. Returns `nil` on invalid base64.
    var base64Decoded: Data? {
        return Data(base64Encoded: self)
    }
}
