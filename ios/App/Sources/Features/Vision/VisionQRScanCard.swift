import SwiftUI
import UIKit

/// Inline QR-code card surfaced above the analysis sheet in Vision mode.
///
/// Shows the decoded text, then "Use in prompt", "Copy", and (when the value
/// looks like a URL) "Open URL". A trailing × dismisses the card without
/// consuming it. Stays on screen until the host dismisses or the auto-expire
/// (`VisionViewModel.qrCardVisibleDuration`) fires.
struct VisionQRScanCard: View {
    let payload: VisionViewModel.ScannedQR
    /// Drives the auto-expire timer in the parent. We don't track it locally
    /// so the card always renders deterministically with the same now-or-not-yet
    /// state from the host.
    var onUse: () -> Void
    var onCopy: () -> Void
    var onOpenURL: (() -> Void)?
    var onDismiss: () -> Void

    /// True for ~1.2s after Copy is tapped — flashes "Copied" in the pill.
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            valueText
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(border)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.accent.opacity(0.18), in: Circle())

            Text("QR code detected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss QR card")
        }
    }

    private var valueText: some View {
        // Three-line peek keeps the card tight without flooding the band.
        Text(payload.value)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(3)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.surfaceElevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .textSelection(.enabled)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            actionPill(
                title: "Use in prompt",
                systemImage: "text.badge.plus",
                primary: true,
                action: onUse
            )
            actionPill(
                title: didCopy ? "Copied" : "Copy",
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                primary: false,
                action: copyTapped
            )
            if let onOpenURL, payload.url != nil {
                actionPill(
                    title: "Open URL",
                    systemImage: "arrow.up.right.square",
                    primary: false,
                    action: onOpenURL
                )
            }
        }
    }

    private func copyTapped() {
        UIPasteboard.general.string = payload.value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onCopy()
        withAnimation(.easeOut(duration: 0.18)) { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }

    private func actionPill(
        title: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .foregroundStyle(primary ? Theme.background : Theme.textPrimary)
            .background(
                primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceElevated),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    primary ? Color.clear : Theme.separator.opacity(0.7),
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Theme.surface.opacity(0.98))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
    }
}
