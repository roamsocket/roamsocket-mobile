import SwiftUI

/// A rounded pill control used in the composer's bottom row (model, permission).
struct Pill: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The model-selector pill shown in the chat + coding-session composers.
///
/// When the user has a valid model + API key, it renders as a chevron
/// pill that opens the model picker. When the user has no usable model
/// yet, it switches to an accent-tinted "+ Add a model" CTA that opens
/// the provider settings screen so they can paste a key. The component
/// pulls reactive state from the environment so callers don't have to
/// pass anything in besides the two actions.
struct ModelSelectorPill: View {
    @EnvironmentObject var state: AppState
    var modelDisplayName: String
    var onPick: () -> Void
    var onAddModel: () -> Void

    var body: some View {
        Button {
            if hasUsableModel { onPick() } else { onAddModel() }
        } label: {
            if hasUsableModel {
                HStack(spacing: 4) {
                    Text(modelDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surfaceElevated, in: Capsule())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add a model")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.accent.opacity(0.15), in: Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    /// A usable model needs an entry AND (for cloud providers) an API key.
    /// On-device Metal is chat-only and needs no key.
    var hasUsableModel: Bool {
        guard let model = state.selectedModel else { return false }
        if !model.provider.requiresAPIKey { return true }
        return !state.resolvedAPIKey(for: model.provider).isEmpty
    }
}

/// A tappable card used for the composer suggestions (IMG_0987).
struct SuggestionCard: View {
    let attributed: AttributedString
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(attributed)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
    }
}

/// A selectable list row with an optional trailing blue checkmark (IMG_0989/0991).
struct SelectableRow<Leading: View>: View {
    var title: String
    var subtitle: String? = nil
    var isSelected: Bool
    @ViewBuilder var leading: () -> Leading
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(title)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.selection)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension SelectableRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, isSelected: isSelected, leading: { EmptyView() }, action: action)
    }
}

/// The small cloud glyph used next to environments (IMG_0989).
struct CloudGlyph: View {
    var body: some View {
        Image(systemName: "cloud")
            .font(.system(size: 18))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// The GitHub mark used on the repo chip (IMG_0987).
struct GitHubGlyph: View {
    var body: some View {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
    }
}

/// A titled bottom-sheet scaffold with a close button (used by the pickers).
struct SheetScaffold<Content: View>: View {
    let title: String
    var trailing: AnyView?
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let trailing { trailing }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            content()
        }
        .background(Theme.background)
    }
}

/// A badge showing a count (used in connectors list).
struct CountBadge: View {
    let count: Int
    
    var body: some View {
        Text("\(count)")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 8)
            .background(Theme.selection, in: Capsule())
    }
}

/// A toggle row with icon, title, and switch (used in Add to Chat sheet).
struct ToggleRow: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var iconColor: Color = Theme.textSecondary
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.selection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// A beta badge label.
struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.surfaceElevated, in: Capsule())
    }
}
