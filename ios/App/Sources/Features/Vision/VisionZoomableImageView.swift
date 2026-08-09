import SwiftUI
import UIKit

/// Frozen capture preview: fit in a Lens-style frame, pinch-to-zoom + pan.
/// Lives in the band *above* the analysis card so the photo stays visible.
struct VisionZoomableImageView: View {
    let image: UIImage
    /// Identity that resets zoom when a new shot is frozen.
    var resetID: UUID?

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let box = fittedImageSize(in: geo.size)

            ZStack {
                Color.black

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: box.width, height: box.height)
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        // Google Lens–style corner brackets around the photo.
                        LensCornerBrackets(cornerRadius: 14)
                            .frame(width: box.width, height: box.height)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                    .gesture(zoomAndPanGesture(container: geo.size, imageBox: box))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            if scale > 1.05 {
                                resetZoom()
                            } else {
                                scale = 2.2
                                baseScale = 2.2
                            }
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .accessibilityLabel("Captured photo")
            .accessibilityHint("Pinch to zoom, drag to pan, double-tap to toggle zoom")
        }
        .onChange(of: resetID) { _, _ in
            resetZoom()
        }
        .onAppear {
            resetZoom()
        }
    }

    // MARK: - Layout

    private func fittedImageSize(in container: CGSize) -> CGSize {
        let insetX: CGFloat = 18
        let insetY: CGFloat = 10
        let maxW = max(1, container.width - insetX * 2)
        let maxH = max(1, container.height - insetY * 2)
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        let scale = min(maxW / iw, maxH / ih)
        return CGSize(width: iw * scale, height: ih * scale)
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    // MARK: - Gestures

    private func zoomAndPanGesture(container: CGSize, imageBox: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let next = baseScale * value.magnification
                    scale = min(max(next, minScale * 0.92), maxScale)
                }
                .onEnded { _ in
                    if scale < minScale {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            resetZoom()
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
                    guard scale > 1.02 else { return }
                    offset = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
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
}

// MARK: - Corner brackets (Lens-style)

private struct LensCornerBrackets: View {
    var cornerRadius: CGFloat = 14
    var armLength: CGFloat = 26
    var lineWidth: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let l = min(armLength, min(w, h) * 0.18)

            ZStack {
                // Soft outer ring so the frame reads on busy photos.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)

                Path { path in
                    // Top-leading
                    path.move(to: CGPoint(x: 0, y: l))
                    path.addLine(to: CGPoint(x: 0, y: cornerRadius))
                    path.addQuadCurve(
                        to: CGPoint(x: cornerRadius, y: 0),
                        control: CGPoint(x: 0, y: 0)
                    )
                    path.addLine(to: CGPoint(x: l, y: 0))

                    // Top-trailing
                    path.move(to: CGPoint(x: w - l, y: 0))
                    path.addLine(to: CGPoint(x: w - cornerRadius, y: 0))
                    path.addQuadCurve(
                        to: CGPoint(x: w, y: cornerRadius),
                        control: CGPoint(x: w, y: 0)
                    )
                    path.addLine(to: CGPoint(x: w, y: l))

                    // Bottom-trailing
                    path.move(to: CGPoint(x: w, y: h - l))
                    path.addLine(to: CGPoint(x: w, y: h - cornerRadius))
                    path.addQuadCurve(
                        to: CGPoint(x: w - cornerRadius, y: h),
                        control: CGPoint(x: w, y: h)
                    )
                    path.addLine(to: CGPoint(x: w - l, y: h))

                    // Bottom-leading
                    path.move(to: CGPoint(x: l, y: h))
                    path.addLine(to: CGPoint(x: cornerRadius, y: h))
                    path.addQuadCurve(
                        to: CGPoint(x: 0, y: h - cornerRadius),
                        control: CGPoint(x: 0, y: h)
                    )
                    path.addLine(to: CGPoint(x: 0, y: h - l))
                }
                .stroke(
                    Color.white.opacity(0.92),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }
}
