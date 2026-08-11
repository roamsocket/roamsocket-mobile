import SwiftUI

/// Add to Chat sheet with options for Files, Project, Tool Access,
/// Skills, and Connectors.
struct AddToChatSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Optional handler fired when the user picks "Start coding session".
    /// The host view does the actual session creation (because it owns the
    /// `sessionConfig` state for the fullScreenCover).
    var onStartCodingSession: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var showProjectPicker = false
    @State private var showCreateProject = false
    @State private var showToolAccessPicker = false

    var body: some View {
        SheetScaffold(
            title: "Add to Chat",
            trailing: AnyView(EmptyView()),
            onClose: { dismiss() }
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    optionsSection
                        .padding(.top, 16)

                    skillsSection
                        .padding(.top, 16)

                    connectorsRow
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.large])
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result {
                viewModel.attachedFileURLs.append(url)
            }
        }
        .confirmationDialog("Add to project", isPresented: $showProjectPicker, titleVisibility: .visible) {
            ForEach(viewModel.history?.projects ?? []) { project in
                Button(project.name) {
                    viewModel.attachCurrentChat(to: project)
                }
            }
            Button("New project…") { showCreateProject = true }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Tool access", isPresented: $showToolAccessPicker, titleVisibility: .visible) {
            ForEach(ChatViewModel.ToolAccess.allCases, id: \.self) { option in
                Button(option.rawValue) { viewModel.toolAccess = option }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showCreateProject) {
            CreateProjectSheet { name, _ in
                viewModel.createProjectAndAttach(name: name)
            }
        }
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(spacing: 0) {
            // Start a coding session — routes through the host view, which
            // owns the fullScreenCover state.
            optionRow(
                systemImage: "chevron.left.forwardslash.chevron.right",
                title: "Start coding session"
            ) {
                let task = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                dismiss()
                // Small delay so the sheet finishes dismissing before the
                // cover / alert presents — avoids the iOS sheet/cover z-fight.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    onStartCodingSession?(task.isEmpty ? "Help me with this repo" : task)
                }
            }

            Divider().background(Theme.separator).padding(.leading, 50)

            // Add files
            optionRow(
                systemImage: "doc.badge.plus",
                title: "Add files"
            ) {
                viewModel.showFilePicker = true
            }

            Divider().background(Theme.separator).padding(.leading, 50)
            
            // Add to project — copies the current chat into a project.
            Button {
                showProjectPicker = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                    
                    Text("Add to project")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                    
                    Spacer()
                    
                    Text(viewModel.currentProject ?? "None")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textSecondary)
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Divider().background(Theme.separator).padding(.leading, 50)
            
            // Tool access — Auto / Manual / Disabled for this chat.
            Button {
                showToolAccessPicker = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "briefcase")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                    
                    Text("Tool access")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                    
                    Spacer()
                    
                    Text(viewModel.toolAccess.rawValue)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textSecondary)
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal, 16)
    }
    
    // MARK: - Skills Section
    
    private var skillsSection: some View {
        VStack(spacing: 0) {
            // Research — multi-query web search + Wikipedia, injected as
            // live sources for this turn (shown as grey tool status lines).
            skillToggleRow(
                systemImage: "magnifyingglass",
                title: "Research",
                subtitle: researchSubtitle,
                isOn: researchToggleBinding
            )

            Divider().background(Theme.separator).padding(.leading, 50)

            // Web search — single SERP for the latest message.
            skillToggleRow(
                systemImage: "globe",
                title: "Web search",
                subtitle: webSearchSubtitle,
                isOn: webSearchToggleBinding
            )
            
            Divider().background(Theme.separator).padding(.leading, 50)
            
            // Health (Apple HealthKit) — injects a read-only stats snapshot
            // into the chat system prompt when enabled.
            HStack(spacing: 14) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.pink)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Health")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.textPrimary)

                        Text("Beta")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }

                    Text(healthSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }

                Spacer()

                if viewModel.isRequestingHealthAccess {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle("", isOn: healthToggleBinding)
                    .labelsHidden()
                    .tint(Theme.selection)
                    .disabled(viewModel.isRequestingHealthAccess || !viewModel.healthService.isHealthDataAvailable)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().background(Theme.separator).padding(.leading, 50)

            // Location — injects a fresh geolocation snapshot into the system
            // prompt when enabled (permission requested on first enable).
            HStack(spacing: 14) {
                Image(systemName: "location.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Location")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)

                    Text(locationSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }

                Spacer()

                if viewModel.isRequestingLocationAccess {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle("", isOn: locationToggleBinding)
                    .labelsHidden()
                    .tint(Theme.selection)
                    .disabled(viewModel.isRequestingLocationAccess || !viewModel.locationService.isLocationServicesEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal, 16)
    }
    
    // MARK: - Connectors Row

    private var connectorsRow: some View {
        Button(action: {
            // The connectors view is presented from ChatView as a sibling
            // sheet; presenting a sheet from inside a sheet on iOS is
            // unreliable, so we dismiss first and ask the host to open
            // the connectors sheet on the next runloop tick.
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                viewModel.showConnectorsView = true
            }
        }) {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                
                Text("Connectors")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
    
    // MARK: - Helper Views
    
    private func optionRow(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func skillToggleRow(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.selection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Research is the deep mode; turning it on implies web search.
    private var researchToggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.researchEnabled },
            set: { newValue in
                viewModel.researchEnabled = newValue
                if newValue {
                    viewModel.webSearchEnabled = true
                }
            }
        )
    }

    private var webSearchToggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.webSearchEnabled || viewModel.researchEnabled },
            set: { newValue in
                viewModel.webSearchEnabled = newValue
                if !newValue {
                    // Web search is required for research.
                    viewModel.researchEnabled = false
                }
            }
        )
    }

    private var researchSubtitle: String {
        if viewModel.researchEnabled {
            return "On — multi-query search and Wikipedia for deeper answers."
        }
        return "Multi-query web search and Wikipedia for deeper answers."
    }

    private var webSearchSubtitle: String {
        if viewModel.researchEnabled {
            return "On with Research — sources are shared with the model each send."
        }
        if viewModel.webSearchEnabled {
            return "On — live web results are attached on each send."
        }
        return "Search the web for the latest message and share sources with the model."
    }

    /// Routes the Health switch through async authorization so the first
    /// enable presents the system HealthKit permission sheet.
    private var healthToggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.healthEnabled },
            set: { newValue in
                Task { await viewModel.setHealthEnabled(newValue) }
            }
        )
    }

    private var healthSubtitle: String {
        if !viewModel.healthService.isHealthDataAvailable {
            return "Apple Health is not available on this device."
        }
        if viewModel.healthEnabled {
            return "Apple Health is on. Stats are shared with the model for this chat."
        }
        switch viewModel.healthService.authorizationState {
        case .denied:
            return "Access denied — enable in Settings → Privacy → Health."
        case .unavailable:
            return "Apple Health is not available on this device."
        default:
            return "Ask about steps, sleep, workouts, and more."
        }
    }

    /// Routes the Location switch through async authorization so the first
    /// enable presents the system location permission sheet.
    private var locationToggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.locationEnabled },
            set: { newValue in
                Task { await viewModel.setLocationEnabled(newValue) }
            }
        )
    }

    private var locationSubtitle: String {
        if !viewModel.locationService.isLocationServicesEnabled {
            return "Location Services are off on this device."
        }
        if viewModel.locationEnabled {
            return "Location is on. Your place is shared with the model for this chat."
        }
        switch viewModel.locationService.authorizationState {
        case .denied, .restricted:
            return "Access denied — enable in Settings → Privacy → Location."
        default:
            return "Share where you are for local answers and context."
        }
    }
}

#Preview {
    AddToChatSheet(viewModel: ChatViewModel())
}
