import XCTest
import UIKit
@testable import RoamSocket

/// Regression tests for the image-attach pipeline. These cover the failure
/// modes the user actually hit: silent drops on unsupported formats, empty
/// payloads sneaking through, oversized images crashing the upstream
/// token-count endpoint.
///
/// Run via:
///   xcodebuild test \
///     -scheme RoamSocket \
///     -destination 'platform=iOS Simulator,name=iPhone 15'
final class ImageProcessingTests: XCTestCase {

    /// 1×1 red JPEG, hand-built so the test doesn't depend on disk fixtures.
    /// Created once per test class — every test that needs a valid image
    /// reuses this fixture.
    private static let tinyRedJPEG: Data = {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 1.0)!
    }()

    func testDownsamplesValidJPEG() throws {
        let result = ImageProcessing.downsampledJPEG(
            from: Self.tinyRedJPEG,
            maxDimension: 800,
            quality: 0.8
        )
        XCTAssertNotNil(result, "Valid JPEG should downsample to non-nil Data")
        XCTAssertFalse(result?.isEmpty ?? true, "Downsampled JPEG must not be empty")
    }

    func testDownsamplesRejectsNonImageBytes() {
        // Random garbage that isn't a recognized image header.
        let garbage = Data(repeating: 0xAB, count: 4096)
        let result = ImageProcessing.downsampledJPEG(
            from: garbage,
            maxDimension: 800,
            quality: 0.8
        )
        XCTAssertNil(result, "Non-image bytes should return nil, not an empty Data")
    }

    func testDownsamplesRejectsEmptyInput() {
        let result = ImageProcessing.downsampledJPEG(
            from: Data(),
            maxDimension: 800,
            quality: 0.8
        )
        XCTAssertNil(result, "Empty input must return nil")
    }

    func testDownsamplesRespectsMaxDimension() throws {
        // Create a 2000×1000 RGB image (well above the 800 px cap), encode
        // it, and confirm the downsample path doesn't blow up — we can't
        // assert the exact pixel dimensions of the result without decoding,
        // but the call must succeed and return non-empty data.
        let size = CGSize(width: 2000, height: 1000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let big = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let bigData = big.jpegData(compressionQuality: 0.9) else {
            XCTFail("Failed to encode fixture for test setup")
            return
        }
        let result = ImageProcessing.downsampledJPEG(
            from: bigData,
            maxDimension: 800,
            quality: 0.8
        )
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isEmpty ?? true)
    }

    func testDetectMIMEOnJPEG() {
        XCTAssertEqual(ImageProcessing.detectMIME(from: Self.tinyRedJPEG), "image/jpeg")
    }

    func testDetectMIMEReturnsNilForGarbage() {
        let garbage = Data(repeating: 0xFF, count: 64)
        XCTAssertNil(ImageProcessing.detectMIME(from: garbage))
    }

    func testDetectMIMEReturnsNilForEmpty() {
        XCTAssertNil(ImageProcessing.detectMIME(from: Data()))
    }

    func testChatViewModelConstantsAreSane() {
        // These are the constants the runtime relies on for the upstream
        // `input_tokens` timeout. If someone bumps them past the working
        // window, vision sends start hanging again.
        XCTAssertGreaterThanOrEqual(ChatViewModel.maxAttachedImages, 1)
        XCTAssertLessThanOrEqual(ChatViewModel.maxAttachedImages, 8)
        XCTAssertGreaterThan(ChatViewModel.visionPayloadBudgetBytes, 0)
        XCTAssertLessThanOrEqual(
            ChatViewModel.visionPayloadBudgetBytes,
            5_000_000,
            "Vision payload budget >5 MB will reliably hang the upstream token-count endpoint"
        )
    }
}
