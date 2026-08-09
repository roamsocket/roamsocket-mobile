import SwiftUI
import WidgetKit

@main
struct RoamSocketWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AIThinkingLiveActivity()
        if #available(iOS 18.0, *) {
            OpenChatControl()
            OpenCodeControl()
            OpenVisionControl()
        }
    }
}
