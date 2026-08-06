import SwiftUI

/// Draggable analysis popover: full expanded view or a minimized pill that
/// leaves the camera/image visible for reference.
struct VisionAnalysisSheet: View {
    @ObservedObject var viewModel: VisionViewModel
    var modelDisplayName: String

    @GestureState private var dragOffset: CGFloat = 0

    private let minimizedHeight: CGFloat = 72
    private let expandedFraction: CGFloat = 0.58

    var body: some View {
        GeometryReader { geo in
            let maxExpanded = geo.size.height * expandedFraction
            let targetHeight: CGFloat = {
                switch viewModel.sheetMode {
                case .hidden: return 0
                case .minimized: return minimizedHeight
                case .expanded: return maxExpanded
                }
            }()
            let height = max(0, targetHeight - dragOffset)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                sheetChrome(maxExpanded: maxExpanded, height: height)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: viewModel.sheetMode)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private func sheetChrome(maxExpanded: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            grabber
                .padding(.top, 10)
                .padding(.bottom, 8)

            if viewModel.sheetMode == .minimized {
                minimizedBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                expandedContent
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 22,
                style: .continuous
            )
            .fill(Theme.surface.opacity(0.96))
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 22,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 22,
                    style: .continuous
                )
                .stroke(Theme.separator.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: -4)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(maxExpanded: maxExpanded))
        .onTapGesture {
            if viewModel.sheetMode == .minimized {
                viewModel.setSheetExpanded()
            }
        }
        .opacity(viewModel.sheetMode == .hidden ? 0 : 1)
        .allowsHitTesting(viewModel.sheetMode != .hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(Theme.textTertiary.opacity(0.55))
            .frame(width: 40, height: 5)
    }

    private var minimizedBar: some View {
        HStack(spacing: 12) {
            if let image = viewModel.capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surfaceElevated)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "eye")
                            .foregroundStyle(Theme.textSecondary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.isThinking ? "Analyzing…" : "Analysis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(minimizedSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if viewModel.isThinking {
                ProgressView()
                    .tint(Theme.accent)
            } else {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.isThinking ? "Analyzing image" : "Expand analysis")
        .accessibilityAddTraits(.isButton)
    }

    private var minimizedSubtitle: String {
        if viewModel.isThinking {
            return modelDisplayName
        }
        if case .failed(let msg) = viewModel.phase {
            return msg
        }
        let trimmed = viewModel.analysisText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return modelDisplayName }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(viewModel.isThinking ? "Analyzing" : "Analysis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Text(modelDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceElevated, in: Capsule())
                Button {
                    viewModel.setSheetMinimized()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize analysis")
            }

            if viewModel.isThinking {
                thinkingBlock
            } else if case .failed(let msg) = viewModel.phase {
                Text(msg)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    MarkdownContentView(text: viewModel.analysisText, fontSize: 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var thinkingBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Theme.accent)
                Text("Looking at the photo…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            ThinkingShimmerLines()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func dragGesture(maxExpanded: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                // Positive drag = pull down = shrink.
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.height
                let combined = max(dy, predicted * 0.55)
                switch viewModel.sheetMode {
                case .expanded:
                    if combined > 90 {
                        viewModel.setSheetMinimized()
                    }
                case .minimized:
                    if combined < -40 {
                        viewModel.setSheetExpanded()
                    } else if combined > 80 {
                        // Extra pull on minimized does not dismiss — stay minimized.
                        viewModel.setSheetMinimized()
                    }
                case .hidden:
                    break
                }
            }
    }
}

// MARK: - Thinking shimmer

private struct ThinkingShimmerLines: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shimmerBar(widthFraction: 0.92)
            shimmerBar(widthFraction: 0.78)
            shimmerBar(widthFraction: 0.64)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func shimmerBar(widthFraction: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width * widthFraction
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surfaceElevated)
                .frame(width: w, height: 12)
                .overlay {
                    LinearGradient(
                        colors: [
                            Theme.surfaceElevated.opacity(0),
                            Theme.accent.opacity(0.35),
                            Theme.surfaceElevated.opacity(0),
                        ],
                        startPoint: UnitPoint(x: phase - 0.4, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.1, y: 0.5)
                    )
                    .frame(width: w, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
        }
        .frame(height: 12)
    }
}
