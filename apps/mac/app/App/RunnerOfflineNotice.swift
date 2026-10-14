import SwiftUI

/// Connection failures stay visible beside the conversation they affect.
struct RunnerOfflineNotice: View {
    let name: String
    var body: some View {
        Label("\(name) isn't reachable. Oby will reconnect automatically.", systemImage: "wifi.exclamationmark")
            .font(OBYStyle.caption).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OBYStyle.Space.lg).padding(.vertical, OBYStyle.Space.sm)
    }
}
