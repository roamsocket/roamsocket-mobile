import SwiftUI
import AnyProvCore

/// Claude-style effort control: discrete slider + short labels + long explanation
/// for the selected level.
struct EffortControl: View {
    @Binding var effort: Effort

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Effort")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(effort.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            // Discrete 3-stop slider
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(effort.sliderIndex) },
                        set: { effort = Effort.from(sliderIndex: Int($0.rounded())) }
                    ),
                    in: 0...2,
                    step: 1
                )
                .tint(Theme.accent)

                HStack {
                    ForEach(Effort.allCases, id: \.self) { level in
                        Text(level.displayName)
                            .font(.system(size: 12, weight: effort == level ? .semibold : .regular))
                            .foregroundStyle(effort == level ? Theme.textPrimary : Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: alignment(for: level))
                    }
                }
            }

            // Explanation card for the selection
            VStack(alignment: .leading, spacing: 6) {
                Text(effort.summary)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(effort.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func alignment(for level: Effort) -> Alignment {
        switch level {
        case .low: return .leading
        case .medium: return .center
        case .high: return .trailing
        }
    }
}

#Preview {
    struct Host: View {
        @State var effort: Effort = .high
        var body: some View {
            EffortControl(effort: $effort)
                .padding()
                .background(Theme.background)
        }
    }
    return Host()
}
