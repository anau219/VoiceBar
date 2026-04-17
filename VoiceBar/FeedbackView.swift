import SwiftUI
import AppKit

struct FeedbackView: View {
    @ObservedObject var appState: AppState
    @State private var message = ""
    @State private var email = ""
    @State private var notifyUpdates = false
    @State private var state: SubmitState = .idle

    enum SubmitState { case idle, submitting, success, error(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Send Feedback")
                    .font(.title2).fontWeight(.semibold)
                Text("What's working, what's not, or what you'd love to see.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Message
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Message").font(.callout).fontWeight(.medium)
                        TextEditor(text: $message)
                            .font(.body)
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                    }

                    // Email
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email (optional)").font(.callout).fontWeight(.medium)
                        TextField("your@email.com", text: $email)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !email.isEmpty {
                        Toggle("Notify me about VoiceBar updates", isOn: $notifyUpdates)
                            .font(.callout)
                    }

                    // Auto-collected info
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            infoRow("App version", value: appVersion)
                            infoRow("macOS", value: macOSVersion)
                            infoRow("Model", value: appState.selectedModel)
                        }
                    } label: {
                        Text("Included automatically").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer buttons + status
            HStack {
                switch state {
                case .success:
                    Label("Sent — thanks!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                case .error(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.caption)
                default:
                    EmptyView()
                }

                Spacer()

                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.escape, modifiers: [])

                Button(action: submit) {
                    if case .submitting = state {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send Feedback")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || {
                    if case .submitting = state { return true }
                    return false
                }())
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text(value).font(.caption).foregroundStyle(.primary)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func submit() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .submitting

        Task {
            do {
                try await appState.submitFeedback(
                    message: trimmed,
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    notify: notifyUpdates,
                    appVersion: appVersion,
                    macOSVersion: macOSVersion
                )
                await MainActor.run {
                    state = .success
                    message = ""
                    email = ""
                    notifyUpdates = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { closeWindow() }
                }
            } catch {
                await MainActor.run { state = .error("Failed to send — check your connection.") }
            }
        }
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }
}
