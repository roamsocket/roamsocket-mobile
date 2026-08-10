import SwiftUI
import UIKit

/// Draggable analysis popover with three detents:
/// - **minimized** — compact pill above the shutter (with Retake)
/// - **expanded** — medium card
/// - **full** — tall card that stops *below* the photo band + top chrome
///
/// Drag uses live height (no spring during gesture) and snaps to the nearest detent.
/// Sheet height is resized from the **grabber / title bar only** so the analysis
/// thread can scroll freely (including scrolling back up) without collapsing.
struct VisionAnalysisSheet: View {
    @ObservedObject var viewModel: VisionViewModel
    @EnvironmentObject private var state: AppState
    var modelDisplayName: String
    /// Height of Retake + shutter + bottom chrome padding (for lifting the pill).
    var shutterClearance: CGFloat = 118
    /// Home-indicator inset; expanded backgrounds draw through this region.
    var bottomSafeInset: CGFloat = 0
    /// Top chrome (status + close / model). Full sheet never grows into this band.
    var topChromeClearance: CGFloat = 100
    /// Called when the user taps Retake on the sheet chrome.
    var onRetake: () -> Void = {}

    @FocusState private var composerFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    /// Live height while dragging (nil when at rest — use mode target).
    @State private var dragLiveHeight: CGFloat?
    @State private var dragStartHeight: CGFloat = 0
    /// Full capture/system prompt is shown in a popover, never inline in the thread.
    @State private var showCapturePromptDetail = false
    /// Brief confirmation after copy / save artifact.
    @State private var actionToast: String?


    /// Keep in sync with `VisionView.estimatedSheetOccupiedHeight`.
    /// Tall enough that a portrait still can show more than a postage-stamp crop.
    static let minImageBandHeight: CGFloat = 200
    static let imageSheetGap: CGFloat = 12
    /// Grabber (20) + vertical pad (10) + thumbnail row (40) + vertical pad (10).
    static let minimizedCardHeight: CGFloat = 80

    private let minimizedShutterGap: CGFloat = 14
    private let expandedFraction: CGFloat = 0.46
    private let fullFraction: CGFloat = 0.88
    private let thinkingHeight: CGFloat = 220
    private let contentHorizontalPadding: CGFloat = 18
    private let minimizedHorizontalInset: CGFloat = 12

    private var keyboardVisible: Bool { keyboardHeight > 20 }

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let detents = detentHeights(totalHeight: totalHeight)
            let targetHeight = detents.height(for: viewModel.sheetMode)
            // When the keyboard is up, fit the card into the remaining band between
            // the top chrome and the keyboard — do not keep a tall sheet *and*
            // lift it (that slid content under Close/model and left a gap above
            // the keyboard).
            let height: CGFloat = {
                if let dragLiveHeight { return dragLiveHeight }
                if keyboardVisible,
                   viewModel.sheetMode == .expanded || viewModel.sheetMode == .full
                {
                    let available = totalHeight - topChromeClearance - keyboardHeight
                    return max(240, min(targetHeight, available))
                }
                return targetHeight
            }()

            let bottomLift: CGFloat = {
                switch viewModel.sheetMode {
                case .minimized:
                    return shutterClearance + minimizedShutterGap
                case .expanded, .full, .hidden:
                    // Pin the sheet flush to the top of the software keyboard.
                    return keyboardVisible ? keyboardHeight : 0
                }
            }()

            // ZStack (not a full-screen hit target): empty area above the card
            // passes pinches/pans through to the zoomable still behind.
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                if viewModel.sheetMode != .hidden {
                    sheetChrome(height: height, detents: detents)
                        .padding(.horizontal, viewModel.sheetMode == .minimized ? minimizedHorizontalInset : 0)
                        .padding(.bottom, bottomLift)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        // Only animate detent changes when not mid-drag.
                        .animation(
                            dragLiveHeight == nil
                                ? .interactiveSpring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.12)
                                : nil,
                            value: viewModel.sheetMode
                        )
                        .animation(
                            dragLiveHeight == nil
                                ? .easeOut(duration: 0.22)
                                : nil,
                            value: height
                        )
                }
            }
            .frame(width: geo.size.width, height: totalHeight, alignment: .bottom)
            .animation(.easeOut(duration: 0.22), value: keyboardHeight)
            .onChange(of: viewModel.sheetMode) { _, mode in
                if mode == .minimized || mode == .hidden {
                    composerFocused = false
                }
                // Drop any stale live height when mode is set programmatically.
                if dragLiveHeight != nil, mode != .hidden {
                    dragLiveHeight = nil
                }
            }
            .onChange(of: viewModel.lastUsedPrompt) { _, _ in
                // New shot → dismiss any open prompt detail.
                showCapturePromptDetail = false
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // GeometryReader must not eat hits in the photo band above the card.
        .allowsHitTesting(viewModel.sheetMode != .hidden)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardHeight(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        // No keyboard toolbar here: Done/Send accessories left a floating bar and
        // a gap under the card. Dismiss + Send live on the composer itself.
    }

    // MARK: - Keyboard

    private func updateKeyboardHeight(from note: Notification) {
        guard
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            return
        }
        // Prefer the geometry of *this* window when available so multi-scene /
        // fullScreenCover coordinates stay accurate.
        let screenH = UIScreen.main.bounds.height
        let overlap = max(0, screenH - frame.origin.y)
        // Ignore tiny residual frames when the keyboard is nearly off-screen.
        keyboardHeight = overlap > 20 ? overlap : 0
        if keyboardHeight > 20 {
            if viewModel.sheetMode != .full && viewModel.sheetMode != .hidden {
                viewModel.setSheetFull()
            }
        }
    }

    // MARK: - Detents

    private struct Detents {
        var minimized: CGFloat
        var expanded: CGFloat
        var full: CGFloat

        func height(for mode: VisionViewModel.SheetMode) -> CGFloat {
            switch mode {
            case .hidden: return 0
            case .minimized: return minimized
            case .expanded: return expanded
            case .full: return full
            }
        }

        var sorted: [(VisionViewModel.SheetMode, CGFloat)] {
            [(.minimized, minimized), (.expanded, expanded), (.full, full)]
        }
    }

    private func detentHeights(totalHeight: CGFloat) -> Detents {
        // Leave a permanent photo peek above the card. Growing the sheet into that
        // band used to cover the grabber (and the first lines of the answer) so
        // full-height mode could not be dragged closed.
        let maxByPhoto = max(
            280,
            totalHeight - topChromeClearance - Self.minImageBandHeight - Self.imageSheetGap
        )
        let maxExpanded = min(max(260, totalHeight * expandedFraction), maxByPhoto)
        let maxFull = min(max(maxExpanded + 40, totalHeight * fullFraction), maxByPhoto)

        let expanded: CGFloat = {
            if viewModel.isThinking && !viewModel.isReplying {
                return min(min(maxExpanded, thinkingHeight) + bottomSafeInset * 0.5, maxByPhoto)
            }
            // Cap after safe-area padding so the card never grows over the photo.
            return min(maxExpanded + bottomSafeInset, maxByPhoto)
        }()

        let full: CGFloat = {
            if viewModel.isThinking && !viewModel.isReplying {
                return min(min(maxFull, thinkingHeight + 80) + bottomSafeInset, maxByPhoto)
            }
            // Keyboard path sets height from remaining band in `body`; keep a
            // sensible full target for snaps when the keyboard is down.
            return maxFull
        }()

        return Detents(
            minimized: Self.minimizedCardHeight,
            expanded: expanded,
            full: full
        )
    }

    // MARK: - Chrome

    @ViewBuilder
    private func sheetChrome(height: CGFloat, detents: Detents) -> some View {
        let isMinimized = viewModel.sheetMode == .minimized
        let corner: CGFloat = isMinimized ? 20 : 22

        VStack(spacing: 0) {
            resizeHeader(detents: detents)
                .padding(.horizontal, contentHorizontalPadding)

            if isMinimized {
                minimizedBar(detents: detents)
                    .padding(.horizontal, contentHorizontalPadding)
            } else {
                expandedBody(detents: detents)
                    .padding(.horizontal, contentHorizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .clipped()
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.surface.opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(Theme.separator.opacity(0.7), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: isMinimized ? 16 : 24, y: isMinimized ? 4 : -4)
                .mask(alignment: .top) {
                    if isMinimized {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                    } else {
                        UnevenRoundedRectangle(
                            topLeadingRadius: corner,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: corner,
                            style: .continuous
                        )
                    }
                }
        }
    }

    private func resizeHeader(detents: Detents) -> some View {
        let isMinimized = viewModel.sheetMode == .minimized
        // Tighter grabber when collapsed so top/bottom padding of the pill matches.
        let grabberHit: CGFloat = isMinimized ? 20 : 28
        return VStack(spacing: 0) {
            // Drag only on the grabber — not on title buttons (Retake / chevron).
            ZStack {
                Color.clear
                    .frame(height: grabberHit)
                Capsule()
                    .fill(Theme.textTertiary.opacity(0.65))
                    .frame(width: 44, height: 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(detents: detents))
            .accessibilityLabel("Resize analysis")
            .accessibilityHint("Drag up or down to change height")

            if !isMinimized {
                expandedTitleBar
                    .padding(.bottom, 10)
                    // Title row is also a drag surface (buttons keep their own hits).
                    .simultaneousGesture(dragGesture(detents: detents))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func minimizedBar(detents: Detents) -> some View {
        HStack(spacing: 10) {
            // Expand + drag target (not the camera button).
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
                    Text(viewModel.isThinking
                         ? (viewModel.isReplying ? "Answering…" : "Analyzing…")
                         : "Analysis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(minimizedSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.isThinking {
                    ProgressView()
                        .tint(Theme.accent)
                } else {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.setSheetExpanded()
            }
            .gesture(dragGesture(detents: detents))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(viewModel.isThinking ? "Analyzing image" : "Expand analysis")
            .accessibilityAddTraits(.isButton)

            // Always-visible retake when collapsed — separate hit target from drag.
            Button {
                onRetake()
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceElevated, in: Circle())
                    .overlay {
                        Circle().stroke(Theme.separator.opacity(0.8), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isThinking)
            .opacity(viewModel.isThinking ? 0.45 : 1)
            .accessibilityLabel("Retake photo")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Match the 10pt top gap under the grabber so the pill reads evenly.
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var minimizedSubtitle: String {
        if viewModel.isThinking {
            return viewModel.isReplying ? "Thinking about your question…" : modelDisplayName
        }
        if case .failed(let msg) = viewModel.phase {
            return msg
        }
        if let lastUser = viewModel.turns.last(where: { $0.role == .user }) {
            return lastUser.text.replacingOccurrences(of: "\n", with: " ")
        }
        let trimmed = viewModel.analysisText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return modelDisplayName }
        // Prefer first line (often the answer) for the pill preview.
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return firstLine.replacingOccurrences(of: "\n", with: " ")
    }

    private var expandedTitleBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(titleText)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            if viewModel.isReplying {
                ProgressView()
                    .tint(Theme.accent)
                    .scaleEffect(0.85)
            }

            // Collapsed capture/system prompt — icon only in the chrome so the
            // multi-line instruction never occupies the results thread.
            if hasCapturePromptSummary {
                capturePromptHeaderButton
            }

            Spacer(minLength: 4)

            // Copy analysis + save artifact (icons only).
            if viewModel.canExportAnalysis {
                analysisActionButton(
                    systemImage: "doc.on.doc",
                    label: "Copy analysis"
                ) {
                    copyAnalysis()
                }
                analysisActionButton(
                    systemImage: "square.stack.3d.up",
                    label: "Save as artifact"
                ) {
                    saveAnalysisAsArtifact()
                }
            }

            // Retake lives on the sheet so full/medium states don’t trap the user
            // under the top chrome or behind a tall card.
            if viewModel.capturedImage != nil {
                Button {
                    onRetake()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isThinking)
                .opacity(viewModel.isThinking ? 0.45 : 1)
                .accessibilityLabel("Retake photo")
            }

            // Don’t repeat the top-bar model pill — only a compact label here.
            Text(modelDisplayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surfaceElevated, in: Capsule())
                .layoutPriority(0)
                .accessibilityHidden(true)

            Button {
                composerFocused = false
                if viewModel.sheetMode == .full {
                    viewModel.setSheetExpanded()
                } else {
                    viewModel.setSheetMinimized()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.sheetMode == .full ? "Medium analysis size" : "Minimize analysis")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if let actionToast {
                Text(actionToast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceElevated.opacity(0.96), in: Capsule())
                    .overlay {
                        Capsule().stroke(Theme.separator.opacity(0.7), lineWidth: 1)
                    }
                    .offset(y: 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: actionToast)
    }

    private func analysisActionButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.surfaceElevated, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canExportAnalysis)
        .opacity(viewModel.canExportAnalysis ? 1 : 0.45)
        .accessibilityLabel(label)
    }

    private func copyAnalysis() {
        let text = viewModel.exportableAnalysisText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        flashActionToast("Copied")
    }

    private func saveAnalysisAsArtifact() {
        let text = viewModel.exportableAnalysisText
        guard !text.isEmpty else { return }
        let seedTitle: String = {
            if let preset = viewModel.lastUsedPresetTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !preset.isEmpty {
                return "Vision · \(preset)"
            }
            return "Vision analysis"
        }()
        guard let artifact = state.artifactStore.save(
            chatId: nil,
            messageId: viewModel.turns.last(where: { $0.role == .assistant })?.id,
            content: text,
            title: seedTitle
        ) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        flashActionToast("Saved")
        Task { @MainActor in
            let named = await ArtifactTitleGenerator.suggestTitle(for: text)
            if named != artifact.title {
                state.artifactStore.updateTitle(id: artifact.id, title: named)
            }
        }
    }

    private func flashActionToast(_ message: String) {
        actionToast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if actionToast == message {
                actionToast = nil
            }
        }
    }

    private var hasCapturePromptSummary: Bool {
        !viewModel.lastUsedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.lastUsedPresetTitle != nil
    }

    private var capturePromptDetailTitle: String {
        let title = viewModel.lastUsedPresetTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return "Capture prompt"
    }

    private var capturePromptAccessibilityValue: String {
        let title = viewModel.lastUsedPresetTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        let body = viewModel.lastUsedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return "Custom prompt" }
        let oneLine = body.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 48 { return oneLine }
        return String(oneLine.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Icon in the title bar; full system/capture prompt only in a popover/sheet.
    private var capturePromptHeaderButton: some View {
        let body = viewModel.lastUsedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            showCapturePromptDetail = true
        } label: {
            Image(systemName: "text.quote")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.surfaceElevated, in: Circle())
                .overlay {
                    Circle().stroke(Theme.separator.opacity(0.7), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View capture prompt")
        .accessibilityValue(capturePromptAccessibilityValue)
        .popover(isPresented: $showCapturePromptDetail, attachmentAnchor: .point(.bottom)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(capturePromptDetailTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if body.isEmpty {
                    Text("General analysis (built-in).")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView {
                        Text(body)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 280)
                }
            }
            .padding(16)
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
            .background(Theme.surface)
            // Sheet on iPhone so long preset instructions stay readable.
            .presentationCompactAdaptation(.sheet)
        }
    }

    private var titleText: String {
        if viewModel.isReplying { return "Replying" }
        if case .analyzing = viewModel.phase { return "Analyzing" }
        if viewModel.turns.contains(where: { $0.role == .user }) { return "Vision chat" }
        return "Analysis"
    }

    private func expandedBody(detents: Detents) -> some View {
        VStack(spacing: 0) {
            threadScroll()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if viewModel.canChat || viewModel.isReplying {
                if viewModel.isReplying {
                    followUpThinking
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
                followUpComposer
                    .padding(.top, viewModel.isReplying ? 4 : 8)
                    .padding(.bottom, composerBottomPadding)
            } else {
                Color.clear.frame(height: contentBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func threadScroll() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear
                        .frame(height: 1)
                        .id("vision-thread-top")

                    // Prompt lives in the title bar (collapsed chip + popover).
                    // Thread starts with the answer so long system instructions
                    // never push results below the fold.

                    if case .analyzing = viewModel.phase, viewModel.turns.isEmpty {
                        thinkingBlock
                            .id("vision-analyzing")
                    } else if case .failed(let msg) = viewModel.phase, viewModel.turns.isEmpty {
                        Text(msg)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.red.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    } else {
                        ForEach(viewModel.turns) { turn in
                            turnBubble(turn)
                                .id(turn.id)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("vision-thread-bottom")
                }
                .padding(.top, 2)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.automatic, axes: .vertical)
            // No drag-to-resize on the thread — it was stealing pans and collapsing
            // the sheet so users could not scroll (or scroll back up). Resize lives
            // on the grabber / title bar only.
            .onTapGesture {
                if composerFocused {
                    composerFocused = false
                }
            }
            .onChange(of: viewModel.phase) { oldPhase, newPhase in
                if newPhase == .result, oldPhase == .analyzing {
                    scrollToTop(proxy: proxy)
                }
            }
            .onChange(of: viewModel.turns.count) { oldCount, newCount in
                guard newCount > oldCount else { return }
                if oldCount == 0 {
                    scrollToTop(proxy: proxy)
                    return
                }
                scrollToLatest(proxy: proxy)
            }
            .onChange(of: viewModel.isReplying) { _, replying in
                if replying {
                    scrollToLatest(proxy: proxy)
                }
            }
            .onChange(of: composerFocused) { _, focused in
                if focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("vision-thread-bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            // Lead with the first answer.
            if let firstAssistant = viewModel.turns.first(where: { $0.role == .assistant }) {
                proxy.scrollTo(firstAssistant.id, anchor: .top)
            } else if let first = viewModel.turns.first {
                proxy.scrollTo(first.id, anchor: .top)
            } else {
                proxy.scrollTo("vision-thread-top", anchor: .top)
            }
        }
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                if let last = viewModel.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    proxy.scrollTo("vision-thread-bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func turnBubble(_ turn: VisionChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 36)
                Text(turn.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("You said: \(turn.text)")

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let tools = turn.toolCalls, !tools.isEmpty {
                    visionToolStatusLines(tools)
                }
                if turn.isError {
                    Text(turn.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.red.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if looksLikeRichMarkdown(turn.text) {
                    MarkdownContentView(text: turn.text, fontSize: 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(turn.text)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func visionToolStatusLines(_ tools: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tools) { call in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: visionToolIcon(call))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 14, alignment: .center)
                    Text(call.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func visionToolIcon(_ call: ToolCall) -> String {
        switch call.name {
        case "web_search", "research": return "globe"
        case "wikipedia": return "book"
        default: return "wrench.and.screwdriver"
        }
    }

    private var followUpThinking: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.activeToolCalls.isEmpty {
                visionToolStatusLines(viewModel.activeToolCalls)
            }
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Theme.accent)
                Text(viewModel.activeToolCalls.isEmpty ? "Thinking…" : "Answering…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Model is thinking")
    }

    private var followUpComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                viewModel.isReplying ? "Waiting for reply…" : "Ask about this photo…",
                text: $viewModel.draftText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .focused($composerFocused)
            .disabled(viewModel.isReplying)
            .opacity(viewModel.isReplying ? 0.55 : 1)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        composerFocused ? Theme.accent.opacity(0.55) : Theme.separator.opacity(0.8),
                        lineWidth: 1
                    )
            }
            .submitLabel(.send)
            .onSubmit {
                sendFollowUp()
            }

            // Dismiss + Send stay on the card (no system keyboard accessory bar).
            if composerFocused && !viewModel.isReplying {
                Button {
                    composerFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss keyboard")
            }

            Button {
                sendFollowUp()
            } label: {
                Group {
                    if viewModel.isReplying {
                        ProgressView()
                            .tint(Theme.background)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(viewModel.canSendFollowUp ? Theme.background : Theme.textSecondary)
                    }
                }
                .frame(width: 36, height: 36)
                .background(
                    viewModel.canSendFollowUp || viewModel.isReplying ? Theme.accent : Theme.surfaceElevated,
                    in: Circle()
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSendFollowUp && !viewModel.isReplying)
            .accessibilityLabel(viewModel.isReplying ? "Waiting for reply" : "Send question")
        }
        .padding(.top, 4)
        .background(Theme.surface.opacity(0.98))
        .onChange(of: composerFocused) { _, focused in
            if focused {
                if viewModel.sheetMode != .full {
                    viewModel.setSheetFull()
                }
            }
        }
    }

    private func sendFollowUp() {
        guard viewModel.canSendFollowUp else { return }
        composerFocused = false
        viewModel.sendFollowUp()
    }

    private var contentBottomPadding: CGFloat {
        // Sheet chrome retake covers most cases; leave a little space for home bar.
        max(bottomSafeInset, 12) + 8
    }

    private var composerBottomPadding: CGFloat {
        // Keyboard: tight flush above keys (sheet already pinned to keyboard top).
        if keyboardVisible {
            return 8
        }
        // Retake lives on the sheet header; only need home-indicator breathing room.
        return max(bottomSafeInset, 8) + 12
    }

    private var thinkingBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.activeToolCalls.isEmpty {
                visionToolStatusLines(viewModel.activeToolCalls)
            }
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Theme.accent)
                Text(
                    viewModel.activeToolCalls.isEmpty
                        ? "Looking at the photo…"
                        : "Looking at the photo with web results…"
                )
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            ThinkingShimmerLines()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func looksLikeRichMarkdown(_ text: String) -> Bool {
        text.contains("```")
            || text.contains("# ")
            || text.contains("## ")
            || text.contains("- ")
            || text.contains("* ")
            || text.contains("**")
            || text.contains("[") && text.contains("](")
    }

    // MARK: - Drag

    /// Grabber / minimized-pill drag — always owns the gesture.
    private func dragGesture(detents: Detents) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                applySheetDrag(translationY: value.translation.height, detents: detents)
            }
            .onEnded { value in
                endSheetDrag(value: value, detents: detents)
            }
    }

    private func applySheetDrag(translationY: CGFloat, detents: Detents) {
        if composerFocused || keyboardVisible { return }
        if dragLiveHeight == nil {
            dragStartHeight = detents.height(for: viewModel.sheetMode)
        }
        // Pull down → smaller sheet; pull up → taller.
        let next = dragStartHeight - translationY
        let lo = detents.minimized * 0.92
        let hi = detents.full * 1.02
        dragLiveHeight = min(hi, max(lo, next))
    }

    private func endSheetDrag(value: DragGesture.Value, detents: Detents) {
        defer {
            dragLiveHeight = nil
        }
        if composerFocused || keyboardVisible { return }

        let start = dragStartHeight > 0
            ? dragStartHeight
            : detents.height(for: viewModel.sheetMode)
        let dy = value.translation.height
        let predicted = value.predictedEndTranslation.height
        // Weight velocity so a short flick still lands cleanly.
        let projected = dy * 0.25 + predicted * 0.75
        let projectedHeight = start - projected

        let velocity = value.velocity.height
        // Strong flick: step one detent in that direction instead of
        // overshooting across all three.
        if abs(velocity) > 900 {
            stepDetent(direction: velocity > 0 ? .down : .up)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        snapToNearestDetent(projectedHeight: projectedHeight, detents: detents)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private enum DetentStep { case up, down }

    private func stepDetent(direction: DetentStep) {
        switch (viewModel.sheetMode, direction) {
        case (.minimized, .up):
            viewModel.setSheetExpanded()
        case (.expanded, .up):
            viewModel.setSheetFull()
        case (.full, .up):
            break
        case (.full, .down):
            viewModel.setSheetExpanded()
        case (.expanded, .down):
            viewModel.setSheetMinimized()
        case (.minimized, .down):
            break
        default:
            break
        }
    }

    private func snapToNearestDetent(projectedHeight: CGFloat, detents: Detents) {
        let nearest = detents.sorted.min { a, b in
            abs(a.1 - projectedHeight) < abs(b.1 - projectedHeight)
        }?.0 ?? .expanded

        switch nearest {
        case .minimized:
            viewModel.setSheetMinimized()
        case .expanded:
            viewModel.setSheetExpanded()
        case .full:
            viewModel.setSheetFull()
        case .hidden:
            break
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func shimmerBar(widthFraction: CGFloat) -> some View {
        GeometryReader { geo in
            let w = max(0, geo.size.width * widthFraction)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
