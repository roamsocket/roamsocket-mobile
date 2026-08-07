import SwiftUI
import AnyProvCore

/// First-launch walkthrough: product overview + Lightweight Tasks setup.
struct OnboardingWalkthroughView: View {
    @EnvironmentObject var state: AppState
    var onFinished: () -> Void

    @State private var step = 0
    @State private var settings = LightweightTasksSettings.load()
    @State private var isRefreshingModels = false

    private let totalSteps = 5

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                progressBar
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                TabView(selection: $step) {
                    welcomeStep.tag(0)
                    modesStep.tag(1)
                    lightweightIntroStep.tag(2)
                    lightweightPickStep.tag(3)
                    readyStep.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: step)

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceElevated)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(totalSteps))
            }
        }
        .frame(height: 4)
    }

    private var bottomBar: some View {
        HStack {
            if step > 0 {
                Button("Back") {
                    withAnimation { step -= 1 }
                }
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: primaryAction) {
                Text(step == totalSteps - 1 ? "Get started" : "Continue")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 120)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(step == 3 && !canContinueFromPick)
        }
    }

    private var canContinueFromPick: Bool {
        switch settings.mode {
        case .appleFoundation:
            return true // even if unavailable, user can finish and switch later
        case .linkedModel:
            return settings.hasLinkedModel
                || (settings.linkedProvider != nil) // allow continue; model can be set later
        }
    }

    private func primaryAction() {
        if step < totalSteps - 1 {
            if step == 3 {
                settings.save()
            }
            withAnimation { step += 1 }
        } else {
            settings.walkthroughCompleted = true
            settings.save()
            onFinished()
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        walkthroughPage(
            icon: "sparkles",
            title: "Welcome to RoamSocket",
            body: """
            Native chat and coding on your iPhone.

            • Chat talks to providers you bring (Anthropic, OpenAI, and more).
            • Code pairs with the desktop companion for real tools, diffs, and pull requests.
            • On-device Metal models stay on this phone for private chat.
            """
        )
    }

    private var modesStep: some View {
        walkthroughPage(
            icon: "laptopcomputer.and.iphone",
            title: "Chat and Code",
            body: """
            Chat works with only an API key — no Mac required.

            Code needs the desktop app on your computer: pair once, pick a repo, and the agent runs tools where your files live. Your phone stays the remote control.
            """
        )
    }

    private var lightweightIntroStep: some View {
        walkthroughPage(
            icon: "bolt.horizontal.circle",
            title: "Lightweight Tasks",
            body: """
            Short helper jobs use a separate brain from your main chat model:

            • Chat titles in Recents
            • Artifact names
            • Commit message suggestions
            • Thinking summaries

            On Apple devices you can use Apple Intelligence for free on-device, or link any model you already pay for.
            """
        )
    }

    private var lightweightPickStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Choose a backend", systemImage: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("You can change this anytime in Settings → Lightweight Tasks.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)

                backendCard(
                    mode: .appleFoundation,
                    subtitle: LightweightTaskRunner.appleFoundationStatusLine,
                    enabled: true
                )
                backendCard(
                    mode: .linkedModel,
                    subtitle: "Cloud or custom endpoint with your API key",
                    enabled: true
                )

                if settings.mode == .linkedModel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Linked model")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        Picker("Provider", selection: linkedProviderBinding) {
                            Text("Select provider…").tag(String?.none)
                            ForEach(ProviderID.allBuiltInCases.filter {
                                $0 != .localMetal && $0 != .appleFoundation
                            }) { p in
                                Text(p.displayName).tag(Optional(p.rawValue))
                            }
                            ForEach(state.customProviders) { c in
                                Text(c.label).tag(Optional(c.providerID.rawValue))
                            }
                        }
                        .pickerStyle(.menu)

                        if settings.linkedProvider != nil {
                            let models = state.providerResults
                                .first(where: { $0.provider == settings.linkedProvider })?
                                .models ?? []
                            if models.isEmpty {
                                Button {
                                    Task {
                                        isRefreshingModels = true
                                        await state.refreshModels()
                                        isRefreshingModels = false
                                    }
                                } label: {
                                    Label(
                                        isRefreshingModels ? "Loading…" : "Load models (needs API key)",
                                        systemImage: "arrow.clockwise"
                                    )
                                }
                                .disabled(isRefreshingModels)
                            } else {
                                Picker("Model", selection: linkedModelBinding) {
                                    Text("Select model…").tag(String?.none)
                                    ForEach(models) { m in
                                        Text(state.displayName(for: m)).tag(Optional(m.modelID))
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }
                    .padding(16)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                }
            }
            .padding(24)
        }
    }

    private var readyStep: some View {
        walkthroughPage(
            icon: "checkmark.circle.fill",
            title: "You’re set",
            body: """
            Add provider keys in Settings when you’re ready to chat.

            For Code, install the desktop companion on your Mac or Windows PC, open pairing, and connect from the phone.

            Lightweight Tasks will use \(settings.mode.displayName)\(settings.mode == .linkedModel && settings.linkedModelID != nil ? " · \(settings.linkedModelID!)" : "").
            """
        )
    }

    // MARK: - Building blocks

    private func walkthroughPage(icon: String, title: String, body: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(body)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 40)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func backendCard(mode: LightweightTasksSettings.Mode, subtitle: String, enabled: Bool) -> some View {
        Button {
            settings.mode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: settings.mode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(settings.mode == mode ? Theme.accent : Theme.textTertiary)
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                    Text(mode.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .stroke(settings.mode == mode ? Theme.accent.opacity(0.6) : Theme.separator, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var linkedProviderBinding: Binding<String?> {
        Binding(
            get: { settings.linkedProviderRaw },
            set: { settings.linkedProviderRaw = $0; settings.linkedModelID = nil }
        )
    }

    private var linkedModelBinding: Binding<String?> {
        Binding(
            get: { settings.linkedModelID },
            set: { settings.linkedModelID = $0 }
        )
    }
}
