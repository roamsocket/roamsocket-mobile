import SwiftUI
import UIKit
import VisionKit

/// Hosts VisionKit's `ImageAnalysisInteraction` so the user can select, drag,
/// and copy text — exactly like Apple Photos — or invoke Look Up / Translate
/// on detected objects. The interaction must be attached to a view that
/// contains the image (a `UIImageView` subclass is the canonical anchor and
/// gives us automatic `contentsRect` math for any zoom/pan transforms).
///
/// `isInteractionEnabled` toggles the interaction on/off so the crop brackets
/// and pinch gestures in the host view keep working when Live Text is off.
final class LiveTextOverlayView: UIImageView {
    /// Apple retains analysis results, so the interaction reuses the same
    /// `ImageAnalysis` instance across re-binds of the same image.
    private var analysis: ImageAnalysis?
    private let interaction = ImageAnalysisInteraction()

    /// Image backing this view. Setting a new image cancels any in-flight
    /// analysis and runs a new one when interaction is enabled.
    override var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            analysis = nil
            interaction.analysis = nil
            setNeedsAnalysis()
        }
    }

    /// When false, the interaction is removed from this view (so crop / pinch
    /// gestures own the gestures) until re-enabled.
    var isInteractionEnabled: Bool = false {
        didSet {
            guard isInteractionEnabled != oldValue else { return }
            applyInteractionEnabled()
            if isInteractionEnabled {
                setNeedsAnalysis()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    override init(image: UIImage!) {
        super.init(image: image)
        commonInit()
    }

    override init(image: UIImage!, highlightedImage: UIImage?) {
        super.init(image: image, highlightedImage: highlightedImage)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func commonInit() {
        contentMode = .scaleAspectFit
        isUserInteractionEnabled = true
        applyInteractionEnabled()
    }

    /// Re-run analysis on the latest still. Runs once per image assignment to
    /// keep VisionKit's workload bounded — analysis is fast but still expensive
    /// enough that we don't want to fire on every layout pass.
    private func setNeedsAnalysis() {
        guard isInteractionEnabled, let image else {
            analysis = nil
            interaction.analysis = nil
            return
        }
        Task { [weak self] in
            await self?.runAnalysis(on: image)
        }
    }

    private func runAnalysis(on image: UIImage) async {
        guard isInteractionEnabled else { return }
        guard self.image === image else { return }
        let analyzer = ImageAnalyzer()
        // Text selection is the headline feature; visualLookUp enables the
        // Apple-Photos subject / landmark / animal lookup affordance for free.
        let configuration = ImageAnalyzer.Configuration([.text, .visualLookUp])
        do {
            let result = try await analyzer.analyze(
                image,
                orientation: .up,
                configuration: configuration
            )
            guard self.image === image, isInteractionEnabled else { return }
            analysis = result
            interaction.analysis = result
            // `.automatic` mirrors Apple Photos: long-press to lift subjects,
            // tap-and-drag to select text, data detectors (URLs, phones, etc.).
            interaction.preferredInteractionTypes = .automatic
        } catch {
            // Quietly skip — VisionKit keeps the interaction bound to whatever
            // it analyzed last. The next image assignment will retrigger.
        }
    }

    private func applyInteractionEnabled() {
        if isInteractionEnabled {
            // Don't double-add if a previous host already wired it.
            if interaction.view !== self {
                removeInteraction(interaction)
                addInteraction(interaction)
            }
        } else {
            removeInteraction(interaction)
        }
    }
}

/// SwiftUI entry point. Place this over the still to enable Photos-style
/// "Copy text", "Look Up", and "Translate" interactions.
struct LiveTextOverlay: UIViewRepresentable {
    let image: UIImage
    var isEnabled: Bool

    func makeUIView(context _: Context) -> LiveTextOverlayView {
        let view = LiveTextOverlayView(image: image)
        view.isInteractionEnabled = isEnabled
        view.accessibilityLabel = "Captured photo"
        view.accessibilityHint = isEnabled
            ? "Tap and drag to select text, then choose Copy, Look Up, or Translate."
            : nil
        return view
    }

    func updateUIView(_ uiView: LiveTextOverlayView, context _: Context) {
        if uiView.image !== image {
            uiView.image = image
        }
        if uiView.isInteractionEnabled != isEnabled {
            uiView.isInteractionEnabled = isEnabled
        }
        uiView.accessibilityHint = isEnabled
            ? "Tap and drag to select text, then choose Copy, Look Up, or Translate."
            : nil
    }
}
