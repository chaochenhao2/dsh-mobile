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

/// Sends the person to pairing until a Harness answers, then to the Session list.
struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.isConnected {
                SessionsView()
            } else {
                ConnectView()
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.isConnected)
    }
}
