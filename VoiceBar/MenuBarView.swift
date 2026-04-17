import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Open VoiceBar") {
                appState.openMainWindow()
            }

            Divider()

            switch appState.status {
            case .idle:
                Button(action: { appState.openMainWindow() }) {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

            case .downloading(let progress):
                Text("Downloading model... \(Int(progress * 100))%")
                ProgressView(value: progress)
                    .frame(width: 180)

            case .loading:
                Label("Loading model...", systemImage: "ellipsis.circle")

            case .recording:
                Label("Recording", systemImage: "mic.fill")
                    .foregroundStyle(.red)
                if appState.streamingText.isEmpty {
                    Text("Speak now · \(appState.hotkeyLabel) to stop · Esc to cancel")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(appState.streamingText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineLimit(4)
                        .frame(maxWidth: 260, alignment: .leading)
                    Text("\(appState.hotkeyLabel) to stop · Esc to cancel")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

            case .transcribing:
                Label("Transcribing...", systemImage: "text.bubble")

            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            Divider()

            if let last = appState.lastTranscription {
                Button("Paste last transcription") {
                    TextInserter.insertText(last)
                }
                .keyboardShortcut("v", modifiers: .command)
                Button("Copy to clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(last, forType: .string)
                }
                Divider()
            }

            Button("Send Feedback") {
                appState.openFeedbackWindow()
            }

            Divider()

            Button("Quit VoiceBar") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(minWidth: 280)
    }
}
