import SwiftUI
import UIKit
import PhotosUI
import AnyProvCore

/// Guided Learning: a Socratic tutor that plans a few steps, teaches one at a
/// time, asks a check-in question, and gives hints instead of answers — then
/// wraps up with a recap and flashcards that save into the deck store.
struct GuidedLearningView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = GuidedLearningViewModel()

    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(Theme.preferredColorScheme)
        .onAppear {
            viewModel.bind(state: state)
            Task {
                await state.refreshModels()
                viewModel.bind(state: state)
            }
        }
        .onChange(of: state.allModels.map(\.id)) { _, _ in
            viewModel.bind(state: state)
        }
        .sheet(isPresented: $viewModel.showModelPicker) {
            GuidedModelPickerSheet(viewModel: viewModel)
                .environmentObject(state)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: photosPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { @MainActor in
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data)
                else { return }
                viewModel.photoThumbnail = image
                viewModel.transcribePhoto(image)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Guided Learning")

            VStack(alignment: .leading, spacing: 1) {
                Text("Guided learning")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let stepTitle = viewModel.stepTitle {
                    Text(stepTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                viewModel.showModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Text(modelLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surfaceElevated, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lesson model")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var modelLabel: String {
        if let model = viewModel.selectedModel {
            return state.displayName(for: model)
        }
        return "Select model"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .setup:
            setupView
        case .planning:
            workingView
        case .teaching:
            lessonView
        case .evaluating:
            lessonView
        case .done:
            doneView
        case .failed:
            failedView
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Learn by being taught, not told")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Pick what to learn. The tutor teaches one step at a time, checks your understanding, and gives hints instead of answers.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)

                sourceChips

                sourceInput

                startButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GuidedLearningSource.allCases) { source in
                    let isSelected = viewModel.selectedSource == source
                    Button {
                        viewModel.selectedSource = source
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: source.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                            Text(source.title)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(isSelected ? Theme.background : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            isSelected ? Theme.accent : Theme.surfaceElevated,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Learn from \(source.title)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var sourceInput: some View {
        switch viewModel.selectedSource {
        case .topic:
            topicInput
        case .notes:
            notesInput(placeholder: "Paste lecture notes, slides, or code…", text: $viewModel.notes)
        case .photo:
            photoInput
        case .deck:
            deckInput
        }
    }

    private var topicInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Topic", systemImage: "lightbulb.max")
            TextField("e.g. How Big O notation works", text: $viewModel.topic, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.separator.opacity(0.6), lineWidth: 1)
                }
        }
    }

    private func notesInput(placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Study material", systemImage: "doc.plaintext")
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(6...12)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.separator.opacity(0.6), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private var photoInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Study material", systemImage: "photo")

            if let thumbnail = viewModel.photoThumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        PhotosPicker(
                            selection: $photosPickerItem,
                            matching: .images
                        ) {
                            Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.surfaceElevated, in: Capsule())
                        }
                        .padding(10)
                    }
                    .overlay {
                        if viewModel.isTranscribingPhoto {
                            Color.black.opacity(0.45)
                                .overlay {
                                    VStack(spacing: 10) {
                                        ProgressView()
                                            .tint(Theme.accent)
                                        Text("Reading your material…")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
            } else {
                PhotosPicker(
                    selection: $photosPickerItem,
                    matching: .images
                ) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 18, weight: .medium))
                        Text("Choose a photo of your material")
                            .font(.system(size: 15, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(16)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.separator.opacity(0.6), lineWidth: 1)
                    }
                }
            }

            if let error = viewModel.photoTranscriptionError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !viewModel.notes.isEmpty {
                notesInput(placeholder: "Transcribed material — edit if needed…", text: $viewModel.notes)
            }
        }
    }

    private var deckInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("From a deck", systemImage: "square.stack.3d.up")
            if store.sortedDecks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No decks yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Scan a page of questions first and the saved deck will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(store.sortedDecks) { deck in
                        let isSelected = viewModel.selectedDeck?.id == deck.id
                        Button {
                            viewModel.selectedDeck = deck
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(deck.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text("\(deck.cards.count) card\(deck.cards.count == 1 ? "" : "s")")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                            }
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        isSelected ? Theme.accent.opacity(0.6) : Theme.separator.opacity(0.6),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var startButton: some View {
        Button {
            viewModel.startLesson()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("Start guided lesson")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                viewModel.canStart && !viewModel.isWorking
                    ? Theme.accent
                    : Theme.surfaceElevated,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canStart || viewModel.isWorking)
        .opacity(viewModel.canStart ? 1 : 0.6)
        .accessibilityLabel("Start guided lesson")
    }

    // MARK: - Working / teaching

    private var workingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text(workingTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(workingDetail)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workingTitle: String {
        switch viewModel.phase {
        case .planning: return "Creating your learning plan…"
        case .evaluating: return "Checking your answer…"
        default: return "Working…"
        }
    }

    private var workingDetail: String {
        switch viewModel.phase {
        case .planning: return "The tutor will lay out a few steps, then start teaching."
        case .evaluating: return "The tutor is reading your answer and deciding what to do next."
        default: return ""
        }
    }

    private var lessonView: some View {
        VStack(spacing: 0) {
            if viewModel.phase == .evaluating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                    Text("Checking your answer…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.surface.opacity(0.6))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !viewModel.plan.isEmpty {
                        planStrip
                    }
                    if let feedback = viewModel.turn?.feedback {
                        feedbackCard(feedback)
                    }
                    if let hint = viewModel.turn?.hint {
                        hintCard(hint)
                    }
                    if let lesson = viewModel.turn?.lesson {
                        lessonCard(lesson)
                    }
                    if let question = viewModel.turn?.question {
                        checkInCard(question)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)

            composer
        }
    }

    private var planStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.plan.enumerated()), id: \.offset) { index, step in
                    let isCurrent = index == viewModel.currentStep
                    let isDone = index < viewModel.currentStep
                    HStack(spacing: 6) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(step)
                            .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isCurrent ? Theme.background : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isCurrent ? Theme.accent : Theme.surfaceElevated,
                        in: Capsule()
                    )
                }
            }
        }
    }

    private func feedbackCard(_ feedback: GuidedFeedback) -> some View {
        let accent = feedback.isCorrect ? Color.green : Color.orange
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.isCorrect ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
            Text(feedback.text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        }
    }

    private func hintCard(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Hint")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.yellow)
                Text(hint)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
        }
    }

    private func lessonCard(_ lesson: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let stepNumber = viewModel.stepNumber {
                    Text("Step \(stepNumber) of \(viewModel.plan.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            MarkdownContentView(text: lesson, fontSize: 16)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator.opacity(0.7), lineWidth: 1)
        }
    }

    private func checkInCard(_ question: GuidedCheckIn) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Your turn")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }

            Text(question.question)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !question.options.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        optionButton(letter: Self.letters[index], option: option)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
        }
    }

    private static let letters = ["A", "B", "C", "D"]

    private func optionButton(letter: String, option: String) -> some View {
        Button {
            viewModel.submitAnswer("\(letter)) \(option)")
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(letter)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                Text(option)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isWorking)
        .opacity(viewModel.isWorking ? 0.6 : 1)
        .accessibilityLabel("Answer \(letter)")
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            TextField(
                viewModel.phase == .done ? "Ask a follow-up question…" : "Type your answer…",
                text: $viewModel.input,
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.system(size: 16))
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .focused($composerFocused)
            .submitLabel(.send)
            .onSubmit {
                submitComposer()
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if viewModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                        .padding(.horizontal, 10)
                } else {
                    Button(action: submitComposer) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 36, height: 36)
                            .background(
                                viewModel.canSubmit ? Theme.accent : Theme.surfaceElevated,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canSubmit)
                    .accessibilityLabel("Send answer")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(Theme.separator, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .disabled(viewModel.isWorking)
    }

    private func submitComposer() {
        guard viewModel.canSubmit else { return }
        composerFocused = false
        viewModel.submitAnswer(viewModel.input)
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    doneBanner

                    if let recap = viewModel.turn?.recap {
                        lessonCard(recap)
                    }

                    if viewModel.savedCardCount > 0 {
                        flashcardSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)

            if viewModel.savedDeck == nil, viewModel.savedCardCount > 0 {
                saveDeckBar
            }

            composer

            Button {
                viewModel.reset()
            } label: {
                Text("Start a new lesson")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a new guided lesson")
        }
    }

    private var doneBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Lesson complete")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Recap is below. Ask a follow-up question any time — the tutor will pick up from where you left off.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var flashcardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Recap flashcards")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            LazyVStack(spacing: 10) {
                ForEach(Array((viewModel.turn?.cards ?? []).enumerated()), id: \.offset) { index, card in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(index + 1). \(card.question)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(card.answer)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        if !card.reasoning.isEmpty {
                            Text(card.reasoning)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.separator.opacity(0.7), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var saveDeckBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.separator.opacity(0.7))
                .frame(height: 1)

            Button {
                viewModel.saveCards()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Save \(viewModel.savedCardCount) flashcards to a deck")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityLabel("Save flashcards to a deck")
        }
        .background(Theme.background)
    }

    // MARK: - Failed

    private var failedView: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color.orange)
                Text("The tutor got interrupted")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(viewModel.errorMessage ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                HStack(spacing: 12) {
                    Button {
                        viewModel.reset()
                    } label: {
                        Text("Start over")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.retry()
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ObservedObject private var store = FlashcardDeckStore.shared
    @State private var photosPickerItem: PhotosPickerItem?
}

// MARK: - Guided model picker
// Mirrors StudyModelPickerSheet grouping (provider sections, rawValue sort).
// Lists every model — Guided Learning is mostly text-only; photo material
// auto-resolves a vision model.

private struct GuidedModelPickerSheet: View {
    @ObservedObject var viewModel: GuidedLearningViewModel
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showLocalMetal = false
    @State private var showProviderSettings = false
    @State private var expandedProviders: Set<ProviderID> = []

    private var grouped: [(ProviderID, [AIModel])] {
        let map = Dictionary(grouping: state.allModels, by: \.provider)
        return map.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
            (id, map[id] ?? [])
        }
    }

    var body: some View {
        SheetScaffold(title: "Lesson model", trailing: nil, onClose: { dismiss() }) {
            if state.allModels.isEmpty {
                emptyModels
            } else {
                List {
                    ForEach(grouped, id: \.0) { provider, list in
                        Section {
                            DisclosureGroup(isExpanded: providerBinding(for: provider)) {
                                ForEach(list) { model in
                                    modelRow(model)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(provider.displayName)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("\(list.count) model\(list.count == 1 ? "" : "s")")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textTertiary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .tint(Theme.textSecondary)
                            .listRowBackground(Theme.surface)
                        }
                    }

                    Section {
                        Button {
                            showLocalMetal = true
                        } label: {
                            Label("Download on-device models", systemImage: "arrow.down.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .listRowBackground(Theme.surface)

                        Button {
                            showProviderSettings = true
                        } label: {
                            Label("Add API key…", systemImage: "key")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .listRowBackground(Theme.surface)
                    } footer: {
                        Text("Photo study material needs a vision-capable model.")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $showLocalMetal, onDismiss: {
            Task {
                await state.refreshModels()
                viewModel.bind(state: state)
            }
        }) {
            LocalMetalSettingsView()
                .environmentObject(state)
        }
        .sheet(isPresented: $showProviderSettings, onDismiss: {
            Task {
                await state.refreshModels()
                viewModel.bind(state: state)
            }
        }) {
            AppSettingsView()
                .environmentObject(state)
        }
        .task {
            if let selected = viewModel.selectedModel {
                expandedProviders.insert(selected.provider)
            }
        }
    }

    private func providerBinding(for provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(provider) },
            set: { expanded in
                if expanded { expandedProviders.insert(provider) }
                else { expandedProviders.remove(provider) }
            }
        )
    }

    private func modelRow(_ model: AIModel) -> some View {
        Button {
            viewModel.selectedModel = model
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.displayName(for: model))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(model.modelID)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if viewModel.selectedModel?.id == model.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .listRowBackground(Theme.surface)
    }

    private var emptyModels: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 8) {
                Text("No models")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Download an on-device model, or add an API key for OpenAI, Anthropic, OpenRouter, or xAI in Settings.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

            VStack(spacing: 12) {
                Button {
                    showLocalMetal = true
                } label: {
                    Label("Download on-device models", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Theme.background)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showProviderSettings = true
                } label: {
                    Label("Add API key in Settings", systemImage: "key.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Theme.textPrimary)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
