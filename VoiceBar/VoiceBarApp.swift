import SwiftUI

@main
struct VoiceBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .onAppear {
                    appState.setupIfNeeded()
                }
        } label: {
            Image(systemName: appState.menuBarIcon)
                .foregroundStyle(appState.status == .idle ? Color.green : Color.primary)
                .onAppear {
                    appState.launchSetup()
                }
        }
    }
}
