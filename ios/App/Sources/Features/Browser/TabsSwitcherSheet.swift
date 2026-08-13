import SwiftUI

/// Safari-style tab switcher for the embedded browser.
///
/// Layout (top → bottom):
///   1. Header bar with "X Tabs" centered, a Private button on the leading
///      edge, and a Done (✓) button on the trailing edge — mirroring Safari.
///   2. A 2-column grid of `TabPreviewTile`s. Each tile shows a live page
///      snapshot (or a placeholder for empty / unsupported pages), with the
///      page title + URL strip on top and an × in the top-right corner to
///      close just that tab. Tapping the body of a tile switches to it.
///   3. A bottom row with a "+ New Tab" pill on the leading edge — matches
///      Safari's affordance for quickly starting a fresh tab.
///
/// The component is intentionally decoupled from `BrowserStore` — it only
/// takes a `tabs` array and the few callbacks it needs. That keeps the
/// switcher easy to preview in isolation and avoids threading a global
/// `AppState` through it.
struct TabsSwitcherSheet: View {
    let tabs: [BrowserTab]
    let activeTabID: BrowserTab.ID?
    var onSelect: (BrowserTab.ID) -> Void
    var onCloseTab: (BrowserTab.ID) -> Void
    var onNewTab: () -> Void
    var onDone: () -> Void
    /// Called once when the sheet appears so the caller can refresh the
    /// cached page snapshots. The sheet doesn't await this — it just kicks
    /// off the task; the grid re-renders automatically when each
    /// `BrowserTab.snapshot` republishes.
    var refreshSnapshots: (() -> Void)? = nil

    /// Two columns at iPhone widths; the gap is kept tight so the tiles
    /// feel like a continuous grid (matching Safari's spacing) but loose
    /// enough that the × close button on the top-right has room to breathe.
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            grid
            footer
        }
        .background(Theme.background)
        .onAppear { refreshSnapshots?() }
    }

    // MARK: - Header

    /// Safari's pattern: "X Tabs" centered, Private on the left, Done on
    /// the right. We don't render the page content underneath the header
    /// (the grid does that), so the title font is the only thing tying the
    /// view together visually — kept at 17pt semibold to match Safari's
    /// sheet title size.
    private var header: some View {
        ZStack {
            Text("\(tabs.count) \(tabs.count == 1 ? "Tab" : "Tabs")")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel("\(tabs.count) open tabs")
            HStack {
                // "Private" pill — matches Safari's visual. We don't have
                // a separate Private-mode tab group yet, so the tap is a
                // no-op for now; keep it visible so the layout matches
                // Safari and we can wire it up later without re-doing the
                // chrome. A disabled-looking pill would feel broken, so
                // it's styled the same as the active Done button instead.
                Button(action: {}) {
                    Text("Private")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Private browsing (coming soon)")

                Spacer()

                // Done — accent-tinted circle with a checkmark, same shape
                // as the screenshot you shared. Single tap dismisses the
                // sheet and returns to whatever tab was selected (or the
                // previously-active tab if the user only closed tabs).
                Button(action: onDone) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.inkOnAccent)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(tabs) { tab in
                    TabPreviewTile(
                        tab: tab,
                        isActive: tab.id == activeTabID,
                        onSelect: { onSelect(tab.id) },
                        onClose: { onCloseTab(tab.id) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Footer

    /// Single "+ New Tab" button on the leading edge, matching Safari.
    /// Not full-width — Safari's pill is compact and sits over the bottom
    /// safe-area inset.
    private var footer: some View {
        HStack {
            Button(action: onNewTab) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("New Tab")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Theme.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open new tab")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }
}

// MARK: - Tile

/// One tile in the grid: a rounded rectangle showing a snapshot of the
/// page (or a placeholder), with a small header strip containing a
/// favicon-sized dot, the page title, and the URL. An × button sits in
/// the top-right corner of the tile body for one-tap close. The whole
/// tile is tappable to switch to that tab.
private struct TabPreviewTile: View {
    @ObservedObject var tab: BrowserTab
    let isActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    /// Aspect ratio of a Safari tile is roughly 9:16 — taller than a
    /// screenshot. We use a slightly stubbier 3:4 because real web pages
    /// usually render with more horizontal content than a phone screen
    /// can fit, and a 3:4 tile gives the snapshot more room without
    /// making the grid feel cramped.
    private let aspect: CGFloat = 3.0 / 4.0

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                headerStrip
                previewArea
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    // Slightly thicker + accent border on the active tile
                    // so the user can see which tab is live without
                    // reading the title. Matches Safari's behavior.
                    .strokeBorder(
                        isActive ? Theme.accent : Theme.separator,
                        lineWidth: isActive ? 2 : 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
            .aspectRatio(aspect, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// The thin strip at the top of every tile: a tiny "favicon" dot, the
    /// page title, and the host. We deliberately don't try to render a
    /// real favicon — the webview's favicon API is async and unreliable,
    /// and a uniform dot reads cleaner than half-loaded broken images.
    private var headerStrip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(faviconColor)
                .frame(width: 10, height: 10)
                .overlay(
                    // First-letter of the host inside the dot, so each
                    // tile is visually distinct even when the pages are
                    // unrecognizable from the snapshot. Letter is
                    // uppercase to match how Safari's favicon dots read.
                    Text(hostInitial)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.inkOnAccent)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let host = displayHost, !host.isEmpty {
                    Text(host)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // × close button. Sits inside the header strip (not floating
            // over the preview) so it never accidentally closes the tab
            // when the user means to switch to it. The hit area is
            // slightly larger than the visible circle to make it easy
            // to tap.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surfaceElevated)
    }

    /// The page preview area. Three branches:
    ///   1. Tab has a cached snapshot → show it, fitted to the tile.
    ///   2. Tab has a URL but no snapshot yet (snapshot in flight, or
    ///      `takeSnapshot` returned nil) → show a soft placeholder with
    ///      the host so the tile isn't empty.
    ///   3. Tab is empty (Start Page) → show the same placeholder with
    ///      "Start Page" as the label.
    @ViewBuilder
    private var previewArea: some View {
        if let snapshot = tab.snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .aspectRatio(contentMode: .fill) // fill so the tile is solid even if snapshot is a different aspect
                .clipped()
        } else {
            placeholder
        }
    }

    /// Used when we don't have a snapshot yet. A soft gradient field
    /// with a centered label that hints at what the page is. Not a
    /// spinner — Safari uses a static placeholder too, and an
    /// always-spinning loader on every tile when the switcher opens
    /// would feel busy.
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.surfaceElevated, Theme.field],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
                Text(tab.urlString.isEmpty ? "Start Page" : "Loading preview…")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Display helpers

    private var displayHost: String? {
        guard let host = URL(string: tab.urlString)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var hostInitial: String {
        guard let host = displayHost, let first = host.first else { return "•" }
        return String(first).uppercased()
    }

    /// Stable color for the favicon dot, derived from the host so the
    /// same site always gets the same color across visits. Hash → hue;
    /// saturation/lightness are pinned so the dot reads as a UI element
    /// rather than a random color blob.
    private var faviconColor: Color {
        guard let host = displayHost else { return Theme.textTertiary }
        let hash = abs(host.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        parts.append(tab.title.isEmpty ? "New Tab" : tab.title)
        if let host = displayHost {
            parts.append(host)
        }
        if isActive { parts.append("current tab") }
        return parts.joined(separator: ", ")
    }
}
