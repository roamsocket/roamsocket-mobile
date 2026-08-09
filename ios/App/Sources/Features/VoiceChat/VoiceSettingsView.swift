import SwiftUI
import AVFoundation
import AnyProvCore

/// Engine + voice pickers for spoken replies (neural cloud or on-device).
struct VoiceSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var settings = VoiceSettingsStore.shared

    @State private var systemVoices: [AVSpeechSynthesisVoice] = []
    @State private var elevenVoices: [ElevenLabsVoice] = VoiceSettingsStore.elevenLabsPresetVoices
    @State private var loadingEleven = false
    @State private var elevenError: String?

    private var credentials: VoiceTTSCredentials {
        VoiceTTSCredentials(
            openAIKey: state.apiKey(for: .openai),
            elevenLabsKey: state.voiceAPIKey(for: VoiceSettingsStore.elevenLabsVoiceKeyID)
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        engineSection
                        neuralDetailSection
                        systemVoiceSection
                        rateSection
                        conversationSection
                        helpSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
            .onAppear {
                systemVoices = VoiceSettingsStore.availableSystemVoices()
            }
            .task {
                let synth = SpeechSynthesisService()
                await synth.preparePersonalVoiceIfNeeded(preferPersonal: settings.preferPersonalVoice)
                systemVoices = VoiceSettingsStore.availableSystemVoices()
                await refreshElevenLabsVoicesIfPossible()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .preferredColorScheme(.dark)
    }

    // MARK: - Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Speech engine")
            VStack(spacing: 0) {
                ForEach(VoiceSpeechEngine.allCases) { eng in
                    if eng != VoiceSpeechEngine.allCases.first {
                        Divider().background(Theme.separator)
                    }
                    voiceRow(
                        title: eng.title,
                        subtitle: eng.subtitle + availabilityNote(for: eng),
                        selected: settings.engine == eng
                    ) {
                        settings.engine = eng
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            Text("Active path: \(settings.statusLabel(credentials: credentials))")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    private func availabilityNote(for eng: VoiceSpeechEngine) -> String {
        switch eng {
        case .elevenLabs:
            return credentials.hasElevenLabs ? "" : " · key missing"
        case .openAI:
            return credentials.hasOpenAI ? "" : " · key missing"
        case .freeNeural:
            return " · no key needed"
        default:
            return ""
        }
    }

    // MARK: - Neural detail

    @ViewBuilder
    private var neuralDetailSection: some View {
        let path = settings.resolvedEngine(credentials: credentials)
        if path == .openAI || settings.engine == .openAI || settings.engine == .auto {
            openAISection
        }
        if path == .elevenLabs || settings.engine == .elevenLabs || settings.engine == .auto {
            elevenLabsSection
        }
        if path == .freeNeural || settings.engine == .freeNeural || settings.engine == .auto {
            freeNeuralSection
        }
    }

    private var freeNeuralSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Free neural voice")
            Text("Uses Microsoft Edge neural voices in-app — no API key. Sounds much more natural than Apple’s system TTS. Needs internet; not the same as Siri.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(EdgeFreeTTSService.presetVoices) { voice in
                    if voice.id != EdgeFreeTTSService.presetVoices.first?.id {
                        Divider().background(Theme.separator)
                    }
                    voiceRow(
                        title: voice.name,
                        subtitle: voice.displaySubtitle,
                        selected: settings.freeNeuralVoiceID == voice.id
                    ) {
                        settings.freeNeuralVoiceID = voice.id
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var openAISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("OpenAI voice")
            VStack(spacing: 0) {
                ForEach(VoiceSettingsStore.openAIVoices, id: \.id) { voice in
                    if voice.id != VoiceSettingsStore.openAIVoices.first?.id {
                        Divider().background(Theme.separator)
                    }
                    voiceRow(
                        title: voice.name,
                        subtitle: voice.id,
                        selected: settings.openAIVoice == voice.id
                    ) {
                        settings.openAIVoice = voice.id
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 0) {
                ForEach(VoiceSettingsStore.openAIModels, id: \.id) { model in
                    if model.id != VoiceSettingsStore.openAIModels.first?.id {
                        Divider().background(Theme.separator)
                    }
                    voiceRow(
                        title: model.name,
                        subtitle: model.id,
                        selected: settings.openAIModel == model.id
                    ) {
                        settings.openAIModel = model.id
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            if !credentials.hasOpenAI {
                missingKeyHint(
                    message: "Add your OpenAI API key under Provider API keys to use neural OpenAI voices.",
                    url: ProviderAPIKeyLinks.url(for: .openai)
                )
            }
        }
    }

    private var elevenLabsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("ElevenLabs voice")
                Spacer()
                if loadingEleven {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button("Refresh") {
                        Task { await refreshElevenLabsVoicesIfPossible() }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .disabled(!credentials.hasElevenLabs)
                }
            }

            Text("Free tier includes about 10,000 characters per month (~10 minutes of speech). Paste a free-plan API key under Provider API keys → Voice models.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(elevenVoices) { voice in
                    if voice.id != elevenVoices.first?.id {
                        Divider().background(Theme.separator)
                    }
                    voiceRow(
                        title: voice.name,
                        subtitle: [voice.category, voice.id].compactMap { $0 }.joined(separator: " · "),
                        selected: settings.elevenLabsVoiceID == voice.id
                    ) {
                        settings.elevenLabsVoiceID = voice.id
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 0) {
                ForEach(VoiceSettingsStore.elevenLabsModels, id: \.id) { model in
                    if model.id != VoiceSettingsStore.elevenLabsModels.first?.id {
                        Divider().background(Theme.separator)
                    }
                    voiceRow(
                        title: model.name,
                        subtitle: model.id,
                        selected: settings.elevenLabsModel == model.id
                    ) {
                        settings.elevenLabsModel = model.id
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            if let elevenError {
                Text(elevenError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 4)
            }

            if !credentials.hasElevenLabs {
                missingKeyHint(
                    message: "Add an ElevenLabs API key under Provider API keys → Voice models.",
                    url: ProviderAPIKeyLinks.voiceProviderURL(id: VoiceSettingsStore.elevenLabsVoiceKeyID)
                )
            }
        }
    }

    // MARK: - System

    private var systemVoiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("On-device fallback")

            Toggle(isOn: $settings.preferPersonalVoice) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prefer Personal Voice")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Use your iOS voice clone when neural TTS is unavailable (Settings → Accessibility → Personal Voice).")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.accent)
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 0) {
                voiceRow(
                    title: "Auto system voice",
                    subtitle: systemAutoSubtitle,
                    selected: settings.voiceIdentifier.isEmpty
                ) {
                    settings.voiceIdentifier = ""
                }

                ForEach(systemVoices, id: \.identifier) { voice in
                    Divider().background(Theme.separator)
                    voiceRow(
                        title: voice.name,
                        subtitle: "\(voice.language) · \(voice.qualityLabel)",
                        selected: settings.voiceIdentifier == voice.identifier
                    ) {
                        settings.voiceIdentifier = voice.identifier
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var systemAutoSubtitle: String {
        if let v = settings.resolvedSystemVoice() {
            return "\(v.name) · \(v.qualityLabel)"
        }
        return "HiFi system or Personal Voice"
    }

    private var rateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Speech rate")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Slower")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text("Faster")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Slider(value: $settings.speechRate, in: 0...1)
                    .tint(Theme.accent)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Conversation")
            Toggle(isOn: $settings.continuousConversation) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuous conversation")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Listen again automatically after each spoken reply.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("About")
            Text("Best quality: ElevenLabs (free tier available) or OpenAI. Without a key, Auto uses free neural (Edge) voices, which are far more natural than Apple’s system TTS. Siri’s private voice is not available to third-party apps.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func missingKeyHint(message: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url {
                Button {
                    openURL(url)
                } label: {
                    Label("Get API key", systemImage: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
    }

    private func voiceRow(
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 20))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshElevenLabsVoicesIfPossible() async {
        guard credentials.hasElevenLabs else { return }
        loadingEleven = true
        elevenError = nil
        defer { loadingEleven = false }
        do {
            let remote = try await NeuralTTSService.listElevenLabsVoices(apiKey: credentials.elevenLabsKey)
            if !remote.isEmpty {
                elevenVoices = remote
            }
        } catch {
            elevenError = error.localizedDescription
        }
    }
}
