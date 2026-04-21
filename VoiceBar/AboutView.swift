import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 20) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
            }

            VStack(spacing: 4) {
                Text("VoiceBar")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Version \(appVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Native macOS menu bar dictation.\nHold hotkey · speak · text inserts at cursor.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Link(destination: URL(string: "https://alchemyfy.com")!) {
                HStack(spacing: 4) {
                    Text("Made in Alchemyfy Lab")
                        .font(.callout)
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .frame(width: 320)
    }
}
