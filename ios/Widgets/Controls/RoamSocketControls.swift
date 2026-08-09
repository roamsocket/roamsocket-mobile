import AppIntents
import SwiftUI
import WidgetKit

// Control Center + Lock Screen controls (iOS 18+).
// Users add them via Control Center edit mode or Lock Screen customization.
// Each control runs the matching App Intent and opens the app.

@available(iOS 18.0, *)
struct OpenChatControl: ControlWidget {
    static let kind = "app.roamsocket.control.chat"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenChatIntent()) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
        }
        .displayName("Chat")
        .description("Open RoamSocket Chat.")
    }
}

@available(iOS 18.0, *)
struct OpenCodeControl: ControlWidget {
    static let kind = "app.roamsocket.control.code"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenCodeIntent()) {
                Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .displayName("Code")
        .description("Open RoamSocket Code.")
    }
}

@available(iOS 18.0, *)
struct OpenVisionControl: ControlWidget {
    static let kind = "app.roamsocket.control.vision"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenVisionIntent()) {
                Label("Vision", systemImage: "eye.fill")
            }
        }
        .displayName("Vision")
        .description("Open RoamSocket Vision.")
    }
}
