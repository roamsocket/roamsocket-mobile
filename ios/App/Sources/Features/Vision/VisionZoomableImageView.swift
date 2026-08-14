import SwiftUI
import UIKit
import VisionKit

/// Frozen capture preview: pinch-to-zoom, pan, double-tap toggle, and
/// Lens-style crop corners. Long-press / drag on detected text is handled by
/// VisionKit's `ImageAnalysisOverlayView` (Photos-style "Copy Text"). The
/// overlay is wired into the live text layer at the bottom of this file —
/// keep that relationship when changing hit testing.
///
/// White L-brackets sit on the **crop** region (default: full image) so they
/// stay glued to image corners under zoom/pan. Dragging a corner resizes the
/// crop; releasing re-runs analysis on that region via `onCropCommitted`.
struct VisionZoomableImageView: UIViewControllerRepresentable {
    let image: UIImage
    /// Identity that resets zoom + crop when a new shot is frozen.
    var resetID: UUID?
    /// Single tap (e.g. collapse the analysis card to show more of the photo).
    var onSingleTap: (() -> Void)? = nil
    /// Normalized crop rect in image space (0…1). Called when a corner drag
    /// ends or the crop is otherwise committed (not on every pan frame).
    var onCropCommitted: ((CGRect) -> Void)? = nil
    /// Whether to surface Photos-style "Copy text / Look Up / Translate"
    /// interactions on top of the still. Enabled after the analysis drops.
    var liveTextEnabled: Bool = true

    func makeUIViewController(context _: Context) -> VisionZoomableController {
        let vc = VisionZoomableController()
        vc.image = image
        vc.liveTextEnabled = liveTextEnabled
        vc.onSingleTap = onSingleTap
        vc.onCropCommitted = onCropCommitted
        vc.lastResetID = resetID
        return vc
    }

    func updateUIViewController(_ vc: VisionZoomableController, context _: Context) {
        if vc.image !== image {
            vc.image = image
        }
        vc.onSingleTap = onSingleTap
        vc.onCropCommitted = onCropCommitted
        vc.liveTextEnabled = liveTextEnabled
        if vc.lastResetID != resetID {
            vc.lastResetID = resetID
            vc.resetAll()
        }
    }
}

// MARK: - Controller

/// Single-source-of-truth UIKit controller for the frozen still. Owns:
///
/// - the `LiveTextOverlayView` (the UIImageView VisionKit analyzes), zoom +
///   pan transforms, and image content sizing,
/// - the crop dimming, lens brackets, and corner hit targets,
/// - pinch / pan / double-tap / single-tap gesture recognizers.
///
/// Keeping photo + overlay + crop UI in one coordinate space means
/// VisionKit's text selection rectangles line up with what the user sees,
/// even when zoomed or panned.
final class VisionZoomableController: UIViewController {
    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            guard isViewLoaded else { return }
            applyImage()
            resetAll()
        }
    }

    var onSingleTap: (() -> Void)?
    var onCropCommitted: ((CGRect) -> Void)?
    var lastResetID: UUID?

    var liveTextEnabled: Bool = true {
        didSet {
            guard liveTextEnabled != oldValue else { return }
            applyLiveText()
        }
    }

    // MARK: Tunables

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5
    private let minCropSide: CGFloat = 0.12
    private let handleHitSize: CGFloat = 44

    // MARK: Subviews / model

    private let imageView = LiveTextOverlayView()
    private let dimLayer = CAShapeLayer()
    private let bracketLayer = CAShapeLayer()
    private var cornerHandles: [CropCorner: UIView] = [:]
    private var activeCorner: CropCorner?
    private var cropDragStart: CGRect = .init(x: 0, y: 0, width: 1, height: 1)
    private var cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: Gesture state

    private var pinchScale: CGFloat = 1
    private var pinchStartScale: CGFloat = 1
    private var panOffset: CGSize = .zero
    private var panStartOffset: CGSize = .zero
    private var isPinching = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installImageView()
        installOverlay()
        installGestures()
        applyImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImageView()
        rebuildCropOverlays()
        clampPanOffset(animated: false)
    }

    private func installImageView() {
        view.addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityLabel = "Captured photo"
    }

    private func installOverlay() {
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
        bracketLayer.fillColor = UIColor.clear.cgColor
        bracketLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        bracketLayer.lineWidth = 3.5
        bracketLayer.lineCap = .round
        bracketLayer.lineJoin = .round
        bracketLayer.shadowColor = UIColor.black.cgColor
        bracketLayer.shadowOpacity = 0.35
        bracketLayer.shadowRadius = 1.5
        bracketLayer.shadowOffset = CGSize(width: 0, height: 0.5)
        view.layer.addSublayer(dimLayer)
        view.layer.addSublayer(bracketLayer)

        for corner in CropCorner.allCases {
            let handle = UIView()
            handle.backgroundColor = .clear
            handle.isUserInteractionEnabled = true
            handle.accessibilityLabel = "\(corner.accessibilityName) crop handle"
            handle.accessibilityHint = "Drag to resize the analysis region"
            cornerHandles[corner] = handle
            view.addSubview(handle)
            installCornerGesture(on: handle, corner: corner)
        }
    }

    private func installGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
    }

    // MARK: Image wiring

    private func applyImage() {
        imageView.image = image
        applyLiveText()
    }

    private func applyLiveText() {
        // VisionKit requires the underlying UIImageView to receive touches.
        // We keep the parent view's gesture recognizers on too; their delegates
        // decide who wins below.
        imageView.isInteractionEnabled = liveTextEnabled
        imageView.accessibilityHint = liveTextEnabled
            ? "Tap and drag to select text, then choose Copy, Look Up, or Translate."
            : "Pinch to zoom, drag to pan, drag corners to crop, double-tap to toggle zoom."
    }

    // MARK: Layout

    private func fittedImageSize() -> CGSize {
        guard let image, view.bounds.width > 0, view.bounds.height > 0 else {
            return .zero
        }
        let insetX: CGFloat = 12
        let insetY: CGFloat = 6
        let maxW = max(1, view.bounds.width - insetX * 2)
        let maxH = max(1, view.bounds.height - insetY * 2)
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        let s = min(maxW / iw, maxH / ih)
        return CGSize(width: iw * s, height: ih * s)
    }

    /// The rect the photo actually occupies on screen, post zoom/pan.
    private func imageDisplayRect() -> CGRect {
        let base = fittedImageSize()
        let scaledW = base.width * pinchScale
        let scaledH = base.height * pinchScale
        let originX = (view.bounds.width - scaledW) / 2 + panOffset.width
        let originY = (view.bounds.height - scaledH) / 2 + panOffset.height
        return CGRect(x: originX, y: originY, width: scaledW, height: scaledH)
    }

    private func layoutImageView() {
        let rect = fittedImageSize()
        imageView.frame = CGRect(
            x: (view.bounds.width - rect.width) / 2,
            y: (view.bounds.height - rect.height) / 2,
            width: rect.width,
            height: rect.height
        )
    }

    /// Screen-space crop rect (matches the user's eye / VisionKit text boxes).
    private func cropScreenRect() -> CGRect {
        let img = imageDisplayRect()
        return CGRect(
            x: img.minX + cropNormalized.minX * img.width,
            y: img.minY + cropNormalized.minY * img.height,
            width: cropNormalized.width * img.width,
            height: cropNormalized.height * img.height
        )
    }

    // MARK: Crop overlays (paths + handle positions)

    private func rebuildCropOverlays() {
        let rect = cropScreenRect()
        // Dim outside the crop (even-odd: outer = full bounds, inner = crop).
        let outer = UIBezierPath(rect: view.bounds)
        let inner = UIBezierPath(roundedRect: rect, cornerRadius: min(8, rect.width / 12))
        outer.append(inner)
        outer.usesEvenOddFillRule = true
        dimLayer.path = outer.cgPath

        // Lens brackets (4 L-shaped corners of the crop rect).
        let bracket = UIBezierPath()
        let arm = min(28, min(rect.width, rect.height) * 0.22)
        let radius = min(4, arm * 0.35)
        addCornerPath(bracket, in: rect, corner: .topLeading, arm: arm, radius: radius)
        addCornerPath(bracket, in: rect, corner: .topTrailing, arm: arm, radius: radius)
        addCornerPath(bracket, in: rect, corner: .bottomTrailing, arm: arm, radius: radius)
        addCornerPath(bracket, in: rect, corner: .bottomLeading, arm: arm, radius: radius)
        bracketLayer.path = bracket.cgPath

        for (corner, handle) in cornerHandles {
            handle.frame = CGRect(
                origin: .zero,
                size: CGSize(width: handleHitSize, height: handleHitSize)
            ).offsetBy(dx: corner.point(in: rect).x - handleHitSize / 2,
                       dy: corner.point(in: rect).y - handleHitSize / 2)
        }
    }

    private func addCornerPath(
        _ path: UIBezierPath,
        in rect: CGRect,
        corner: CropCorner,
        arm: CGFloat,
        radius: CGFloat
    ) {
        switch corner {
        case .topLeading:
            let p = CGPoint(x: rect.minX, y: rect.minY)
            path.move(to: CGPoint(x: p.x, y: p.y + arm))
            path.addLine(to: CGPoint(x: p.x, y: p.y + radius))
            path.addQuadCurve(
                to: CGPoint(x: p.x + radius, y: p.y),
                controlPoint: p
            )
            path.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        case .topTrailing:
            let p = CGPoint(x: rect.maxX, y: rect.minY)
            path.move(to: CGPoint(x: p.x - arm, y: p.y))
            path.addLine(to: CGPoint(x: p.x - radius, y: p.y))
            path.addQuadCurve(
                to: CGPoint(x: p.x, y: p.y + radius),
                controlPoint: p
            )
            path.addLine(to: CGPoint(x: p.x, y: p.y + arm))
        case .bottomTrailing:
            let p = CGPoint(x: rect.maxX, y: rect.maxY)
            path.move(to: CGPoint(x: p.x, y: p.y - arm))
            path.addLine(to: CGPoint(x: p.x, y: p.y - radius))
            path.addQuadCurve(
                to: CGPoint(x: p.x - radius, y: p.y),
                controlPoint: p
            )
            path.addLine(to: CGPoint(x: p.x - arm, y: p.y))
        case .bottomLeading:
            let p = CGPoint(x: rect.minX, y: rect.maxY)
            path.move(to: CGPoint(x: p.x + arm, y: p.y))
            path.addLine(to: CGPoint(x: p.x + radius, y: p.y))
            path.addQuadCurve(
                to: CGPoint(x: p.x, y: p.y - radius),
                controlPoint: p
            )
            path.addLine(to: CGPoint(x: p.x, y: p.y - arm))
        }
    }

    // MARK: Reset

    func resetAll() {
        pinchScale = 1
        pinchStartScale = 1
        panOffset = .zero
        panStartOffset = .zero
        cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        activeCorner = nil
        cropDragStart = cropNormalized
        view.layer.removeAllAnimations()
        if isViewLoaded {
            layoutImageView()
            rebuildCropOverlays()
        }
    }

    // MARK: Gesture handlers

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            isPinching = true
            pinchStartScale = pinchScale
            view.layer.removeAllAnimations()
        case .changed:
            let next = pinchStartScale * gr.scale
            pinchScale = min(max(next, minScale * 0.92), maxScale)
            layoutImageView()
            rebuildCropOverlays()
        case .ended, .cancelled, .failed:
            isPinching = false
            if pinchScale < minScale {
                pinchScale = minScale
            } else {
                pinchScale = min(max(pinchScale, minScale), maxScale)
            }
            pinchStartScale = pinchScale
            UIView.animate(
                withDuration: 0.32,
                delay: 0,
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                self.layoutImageView()
                self.rebuildCropOverlays()
            }
            clampPanOffset(animated: true)
        default:
            break
        }
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        guard pinchScale > 1.02 else { return }
        switch gr.state {
        case .began:
            panStartOffset = panOffset
        case .changed:
            let translation = gr.translation(in: view)
            panOffset = CGSize(
                width: panStartOffset.width + translation.x,
                height: panStartOffset.height + translation.y
            )
            layoutImageView()
            rebuildCropOverlays()
        case .ended, .cancelled, .failed:
            clampPanOffset(animated: true)
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_: UITapGestureRecognizer) {
        if pinchScale > 1.05 {
            pinchScale = 1
        } else {
            pinchScale = 2.2
        }
        pinchStartScale = pinchScale
        panOffset = .zero
        panStartOffset = .zero
        UIView.animate(
            withDuration: 0.32,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            self.layoutImageView()
            self.rebuildCropOverlays()
        }
    }

    @objc private func handleSingleTap(_: UITapGestureRecognizer) {
        guard activeCorner == nil else { return }
        onSingleTap?()
    }

    private func clampPanOffset(animated: Bool) {
        let rect = imageDisplayRect()
        let maxX = max(0, (rect.width - view.bounds.width) / 2 + 12)
        let maxY = max(0, (rect.height - view.bounds.height) / 2 + 12)
        let clamped = CGSize(
            width: min(max(panOffset.width, -maxX), maxX),
            height: min(max(panOffset.height, -maxY), maxY)
        )
        let apply = {
            self.panOffset = self.pinchScale <= 1.02 ? .zero : clamped
            self.panStartOffset = self.panOffset
            self.layoutImageView()
            self.rebuildCropOverlays()
        }
        if animated {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0
            ) {
                apply()
            }
        } else {
            apply()
        }
    }

    // MARK: Corner drag

    private func installCornerGesture(on handle: UIView, corner: CropCorner) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCornerPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        handle.addGestureRecognizer(pan)
        // Stash the corner so the selector knows which one it's driving.
        pan.cornerIdentifier = corner.rawValue
        handle.accessibilityIdentifier = corner.rawValue
        handle.addGestureRecognizer(pan)
    }

    @objc private func handleCornerPan(_ gr: UIPanGestureRecognizer) {
        guard let raw = gr.cornerIdentifier, let resolved = CropCorner(rawValue: raw) else {
            return
        }
        switch gr.state {
        case .began:
            cropDragStart = cropNormalized
            activeCorner = resolved
        case .changed:
            let translation = gr.translation(in: view)
            cropNormalized = resizedCrop(
                from: cropDragStart,
                corner: resolved,
                translation: CGSize(width: translation.x, height: translation.y)
            )
            rebuildCropOverlays()
        case .ended, .cancelled, .failed:
            activeCorner = nil
            commitCrop()
        default:
            break
        }
    }

    private func resizedCrop(
        from start: CGRect,
        corner: CropCorner,
        translation: CGSize
    ) -> CGRect {
        let img = imageDisplayRect()
        guard img.width > 1, img.height > 1 else { return start }

        let dx = translation.width / img.width
        let dy = translation.height / img.height

        var minX = start.minX
        var minY = start.minY
        var maxX = start.maxX
        var maxY = start.maxY

        switch corner {
        case .topLeading:
            minX = start.minX + dx
            minY = start.minY + dy
        case .topTrailing:
            maxX = start.maxX + dx
            minY = start.minY + dy
        case .bottomLeading:
            minX = start.minX + dx
            maxY = start.maxY + dy
        case .bottomTrailing:
            maxX = start.maxX + dx
            maxY = start.maxY + dy
        }

        minX = min(max(minX, 0), maxX - minCropSide)
        minY = min(max(minY, 0), maxY - minCropSide)
        maxX = max(min(maxX, 1), minX + minCropSide)
        maxY = max(min(maxY, 1), minY + minCropSide)

        if maxX - minX < minCropSide {
            switch corner {
            case .topLeading, .bottomLeading: minX = maxX - minCropSide
            case .topTrailing, .bottomTrailing: maxX = minX + minCropSide
            }
        }
        if maxY - minY < minCropSide {
            switch corner {
            case .topLeading, .topTrailing: minY = maxY - minCropSide
            case .bottomLeading, .bottomTrailing: maxY = minY + minCropSide
            }
        }

        minX = min(max(minX, 0), 1 - minCropSide)
        minY = min(max(minY, 0), 1 - minCropSide)
        maxX = min(max(maxX, minX + minCropSide), 1)
        maxY = min(max(maxY, minY + minCropSide), 1)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func commitCrop() {
        let c = cropNormalized.standardized
        let clamped = CGRect(
            x: min(max(c.minX, 0), 1 - minCropSide),
            y: min(max(c.minY, 0), 1 - minCropSide),
            width: min(max(c.width, minCropSide), 1),
            height: min(max(c.height, minCropSide), 1)
        )
        cropNormalized = clamped
        onCropCommitted?(clamped)
    }
}

// MARK: - Gesture coordination

extension VisionZoomableController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Pinch + pan can fire together so the photo pans while zooming.
        let isPinch = gestureRecognizer is UIPinchGestureRecognizer
            || other is UIPinchGestureRecognizer
        let isPan = gestureRecognizer is UIPanGestureRecognizer
            || other is UIPanGestureRecognizer
        if isPinch && isPan {
            return true
        }
        return false
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Corner handles own their own touches.
        if let view = touch.view, cornerHandles.values.contains(view) {
            return true
        }
        // VisionKit's `ImageAnalysisInteraction` consumes touches that fall on
        // text / data detectors / subjects. We don't suppress anything else —
        // pinch + pan + single-tap should keep working everywhere else.
        return true
    }
}

// MARK: - Crop corner

private enum CropCorner: String, CaseIterable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var accessibilityName: String {
        switch self {
        case .topLeading: return "Top left"
        case .topTrailing: return "Top right"
        case .bottomLeading: return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeading: return CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

/// Store the corner raw value on each pan recognizer so the selector can read
/// it even when iOS hands us a generic recognizer.
private var kCornerIdentifierKey: UInt8 = 0

private extension UIPanGestureRecognizer {
    var cornerIdentifier: String? {
        get {
            objc_getAssociatedObject(self, &kCornerIdentifierKey) as? String
        }
        set {
            objc_setAssociatedObject(
                self,
                &kCornerIdentifierKey,
                newValue,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
        }
    }
}
