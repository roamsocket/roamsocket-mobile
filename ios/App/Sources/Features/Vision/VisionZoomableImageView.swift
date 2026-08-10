import SwiftUI
import UIKit

/// Frozen capture preview: pinch-to-zoom, pan, and Lens-style crop corners.
/// White L-brackets sit on the **crop** region (default: full image) so they
/// stay glued to image corners under zoom/pan. Dragging a corner resizes the
/// crop; releasing re-runs analysis on that region via `onCropCommitted`.
struct VisionZoomableImageView: View {
    let image: UIImage
    /// Identity that resets zoom + crop when a new shot is frozen.
    var resetID: UUID?
    /// Single tap (e.g. collapse the analysis card to show more of the photo).
    var onSingleTap: (() -> Void)? = nil
    /// Normalized crop rect in image space (0…1). Called when a corner drag ends
    /// or the crop is otherwise committed (not on every pan frame).
    var onCropCommitted: ((CGRect) -> Void)? = nil

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    /// Crop in normalized image coordinates (origin top-leading, size 0…1).
    @State private var cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var cropDragStart: CGRect?
    @State private var activeCorner: CropCorner?

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5
    private let minCropSide: CGFloat = 0.12
    private let handleHitSize: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let box = fittedImageSize(in: geo.size)
            let container = geo.size

            ZStack {
                Color.black

                // Photo layer (zoom + pan).
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: box.width, height: box.height)
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)

                // Dim everything outside the crop, in screen space over the photo.
                cropDimOverlay(box: box, container: container)
                    .allowsHitTesting(false)

                // Crop frame + white corner brackets (track zoom/pan).
                cropFrameOverlay(box: box, container: container)
                    .allowsHitTesting(false)

                // Invisible corner hit targets (priority over pan).
                cornerHandles(box: box, container: container)
            }
            .frame(width: container.width, height: container.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(zoomAndPanGesture(container: container, imageBox: box))
            // Double-tap must be registered before single-tap so both fire correctly.
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    if scale > 1.05 {
                        resetZoomOnly()
                    } else {
                        scale = 2.2
                        baseScale = 2.2
                    }
                }
            }
            .onTapGesture(count: 1) {
                guard activeCorner == nil else { return }
                onSingleTap?()
            }
            .accessibilityLabel("Captured photo")
            .accessibilityHint(
                "Pinch to zoom, drag to pan, drag corners to crop. Double-tap to toggle zoom. Tap to minimize analysis."
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onSingleTap?()
            }
        }
        .onChange(of: resetID) { _, _ in
            resetAll()
        }
        .onAppear {
            resetAll()
        }
    }

    // MARK: - Crop overlays

    @ViewBuilder
    private func cropDimOverlay(box: CGSize, container: CGSize) -> some View {
        let rect = cropScreenRect(box: box, container: container)
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(rect)
            context.fill(
                path,
                with: .color(Color.black.opacity(0.45)),
                style: FillStyle(eoFill: true)
            )
        }
        .frame(width: container.width, height: container.height)
    }

    @ViewBuilder
    private func cropFrameOverlay(box: CGSize, container: CGSize) -> some View {
        let rect = cropScreenRect(box: box, container: container)
        ZStack(alignment: .topLeading) {
            // Subtle edge so the selection reads on bright photos.
            Rectangle()
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .position(x: rect.midX, y: rect.midY)

            LensCornerBrackets()
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .position(x: rect.midX, y: rect.midY)
        }
        .frame(width: container.width, height: container.height)
    }

    @ViewBuilder
    private func cornerHandles(box: CGSize, container: CGSize) -> some View {
        let rect = cropScreenRect(box: box, container: container)
        ForEach(CropCorner.allCases) { corner in
            let point = corner.point(in: rect)
            Color.clear
                .frame(width: handleHitSize, height: handleHitSize)
                .contentShape(Rectangle())
                .position(point)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if cropDragStart == nil {
                                cropDragStart = cropNormalized
                                activeCorner = corner
                            }
                            guard let start = cropDragStart else { return }
                            cropNormalized = resizedCrop(
                                from: start,
                                corner: corner,
                                translation: value.translation,
                                box: box,
                                container: container
                            )
                        }
                        .onEnded { _ in
                            cropDragStart = nil
                            activeCorner = nil
                            commitCrop()
                        }
                )
                .accessibilityLabel("\(corner.accessibilityName) crop handle")
                .accessibilityHint("Drag to resize the analysis region")
        }
    }

    // MARK: - Layout / coordinates

    private func fittedImageSize(in container: CGSize) -> CGSize {
        // Tight insets so the freeze-frame uses almost the whole photo band.
        let insetX: CGFloat = 12
        let insetY: CGFloat = 6
        let maxW = max(1, container.width - insetX * 2)
        let maxH = max(1, container.height - insetY * 2)
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        let s = min(maxW / iw, maxH / ih)
        return CGSize(width: iw * s, height: ih * s)
    }

    /// Image display rect in container space after scale + offset.
    private func imageDisplayRect(box: CGSize, container: CGSize) -> CGRect {
        let displayW = box.width * scale
        let displayH = box.height * scale
        let originX = (container.width - displayW) / 2 + offset.width
        let originY = (container.height - displayH) / 2 + offset.height
        return CGRect(x: originX, y: originY, width: displayW, height: displayH)
    }

    /// Crop rect mapped into container/screen points.
    private func cropScreenRect(box: CGSize, container: CGSize) -> CGRect {
        let img = imageDisplayRect(box: box, container: container)
        return CGRect(
            x: img.minX + cropNormalized.minX * img.width,
            y: img.minY + cropNormalized.minY * img.height,
            width: cropNormalized.width * img.width,
            height: cropNormalized.height * img.height
        )
    }

    private func resetAll() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
        cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropDragStart = nil
        activeCorner = nil
    }

    private func resetZoomOnly() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
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

    // MARK: - Gestures

    private func zoomAndPanGesture(container: CGSize, imageBox: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    guard activeCorner == nil else { return }
                    let next = baseScale * value.magnification
                    scale = min(max(next, minScale * 0.92), maxScale)
                }
                .onEnded { _ in
                    guard activeCorner == nil else { return }
                    if scale < minScale {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            resetZoomOnly()
                        }
                    } else {
                        scale = min(max(scale, minScale), maxScale)
                        baseScale = scale
                        clampOffset(container: container, imageBox: imageBox, animated: true)
                        baseOffset = offset
                    }
                },
            DragGesture()
                .onChanged { value in
                    guard activeCorner == nil else { return }
                    // Allow pan whenever zoomed past 1× so the crop stays reachable.
                    guard scale > 1.02 else { return }
                    offset = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    guard activeCorner == nil else { return }
                    clampOffset(container: container, imageBox: imageBox, animated: true)
                    baseOffset = offset
                }
        )
    }

    private func clampOffset(container: CGSize, imageBox: CGSize, animated: Bool) {
        let scaledW = imageBox.width * scale
        let scaledH = imageBox.height * scale
        let maxX = max(0, (scaledW - container.width) / 2 + 12)
        let maxY = max(0, (scaledH - container.height) / 2 + 12)
        let clamped = CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                offset = scale <= 1.02 ? .zero : clamped
            }
        } else {
            offset = scale <= 1.02 ? .zero : clamped
        }
        if scale <= 1.02 {
            baseOffset = .zero
        }
    }

    /// Resize crop from a corner drag. Translation is in screen points.
    private func resizedCrop(
        from start: CGRect,
        corner: CropCorner,
        translation: CGSize,
        box: CGSize,
        container: CGSize
    ) -> CGRect {
        let img = imageDisplayRect(box: box, container: container)
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

        // Keep minimum size against the opposite edge.
        if maxX - minX < minCropSide {
            switch corner {
            case .topLeading, .bottomLeading:
                minX = maxX - minCropSide
            case .topTrailing, .bottomTrailing:
                maxX = minX + minCropSide
            }
        }
        if maxY - minY < minCropSide {
            switch corner {
            case .topLeading, .topTrailing:
                minY = maxY - minCropSide
            case .bottomLeading, .bottomTrailing:
                maxY = minY + minCropSide
            }
        }

        minX = min(max(minX, 0), 1 - minCropSide)
        minY = min(max(minY, 0), 1 - minCropSide)
        maxX = min(max(maxX, minX + minCropSide), 1)
        maxY = min(max(maxY, minY + minCropSide), 1)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Crop corner

private enum CropCorner: String, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

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

// MARK: - Corner brackets (Lens-style)

private struct LensCornerBrackets: View {
    var armLength: CGFloat = 28
    var lineWidth: CGFloat = 3.5
    var cornerRadius: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let l = min(armLength, min(w, h) * 0.22)
            let r = min(cornerRadius, l * 0.35)

            Path { path in
                // Top-leading
                path.move(to: CGPoint(x: 0, y: l))
                path.addLine(to: CGPoint(x: 0, y: r))
                path.addQuadCurve(
                    to: CGPoint(x: r, y: 0),
                    control: CGPoint(x: 0, y: 0)
                )
                path.addLine(to: CGPoint(x: l, y: 0))

                // Top-trailing
                path.move(to: CGPoint(x: w - l, y: 0))
                path.addLine(to: CGPoint(x: w - r, y: 0))
                path.addQuadCurve(
                    to: CGPoint(x: w, y: r),
                    control: CGPoint(x: w, y: 0)
                )
                path.addLine(to: CGPoint(x: w, y: l))

                // Bottom-trailing
                path.move(to: CGPoint(x: w, y: h - l))
                path.addLine(to: CGPoint(x: w, y: h - r))
                path.addQuadCurve(
                    to: CGPoint(x: w - r, y: h),
                    control: CGPoint(x: w, y: h)
                )
                path.addLine(to: CGPoint(x: w - l, y: h))

                // Bottom-leading
                path.move(to: CGPoint(x: l, y: h))
                path.addLine(to: CGPoint(x: r, y: h))
                path.addQuadCurve(
                    to: CGPoint(x: 0, y: h - r),
                    control: CGPoint(x: 0, y: h)
                )
                path.addLine(to: CGPoint(x: 0, y: h - l))
            }
            .stroke(
                Color.white.opacity(0.95),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        }
        .allowsHitTesting(false)
    }
}
