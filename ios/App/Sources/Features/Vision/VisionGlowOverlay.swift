import SwiftUI

/// Subtle multicolor glow **only on the screen edges** while Vision mode is on.
/// Brightens slightly and runs a thin rim shimmer while the model is thinking.
struct VisionGlowOverlay: View {
    var isThinking: Bool

    @State private var pulse = false
    @State private var hueShift = false

    /// How far the edge glow reaches into the frame (fraction of short side).
    private var edgeDepth: CGFloat { isThinking ? 0.14 : 0.11 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let depth = min(w, h) * edgeDepth

            ZStack {
                // Top rim — soft pink/peach, falls off quickly toward center.
                LinearGradient(
                    colors: [
                        Color(hex: 0xFF8A5C).opacity(rimOpacity * 0.55),
                        Color(hex: 0xFF6B9D).opacity(rimOpacity * 0.35),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: depth)
                .frame(maxHeight: .infinity, alignment: .top)
                .blendMode(.screen)

                // Bottom rim — cool blue
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(hex: 0x6AA9FF).opacity(rimOpacity * 0.4),
                        Color(hex: 0x7C5CFF).opacity(rimOpacity * 0.3),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: depth)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .blendMode(.screen)

                // Left rim
                LinearGradient(
                    colors: [
                        Color(hex: 0x6AA9FF).opacity(rimOpacity * 0.45),
                        Color.clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: depth * 0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blendMode(.screen)

                // Right rim
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(hex: 0xFF6B9D).opacity(rimOpacity * 0.4),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: depth * 0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .blendMode(.screen)

                // Thinking: thin rotating highlight only on a blurred stroke near the edge.
                if isThinking {
                    AngularGradient(
                        colors: [
                            Color(hex: 0xFF8A5C).opacity(0.0),
                            Color(hex: 0xFF6B9D).opacity(0.35),
                            Color(hex: 0x6AA9FF).opacity(0.4),
                            Color(hex: 0xA78BFA).opacity(0.3),
                            Color(hex: 0xFF8A5C).opacity(0.0),
                        ],
                        center: .center,
                        angle: .degrees(hueShift ? 360 : 0)
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .stroke(lineWidth: 10)
                            .blur(radius: 8)
                            .padding(4)
                    )
                    .blendMode(.screen)
                }
            }
            .opacity(pulse ? 1.0 : 0.78)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onAppear { startIdlePulse() }
        .onChange(of: isThinking) { _, thinking in
            if thinking {
                startThinkingPulse()
            } else {
                startIdlePulse()
            }
        }
    }

    private var rimOpacity: Double {
        isThinking ? (pulse ? 0.55 : 0.38) : (pulse ? 0.32 : 0.22)
    }

    private func startIdlePulse() {
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
        withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
            hueShift = true
        }
    }

    private func startThinkingPulse() {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulse = true
        }
        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
            hueShift = true
        }
    }
}
