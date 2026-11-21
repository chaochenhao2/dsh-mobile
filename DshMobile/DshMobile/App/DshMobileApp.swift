import SwiftUI

@main
struct DshMobileApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Shows the Session list directly.
///
/// There is no gate before it any more: paired devices are probed in the
/// background, and the list itself explains when nothing is paired or every
/// device is unreachable. A connect screen would only repeat that.
struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SessionsView()
    }
}
