import SwiftUI
import LaunchAtLogin

struct ModelInfo {
    let id: String
    let displayName: String
    let tagline: String
    let size: String
    let recommended: Bool
}

struct MainView: View {
    @ObservedObject var appState: AppState
    @State private var isCapturingHotkey = false

    private let models: [ModelInfo] = [
        ModelInfo(id: "openai_whisper-large-v3-v20240930_turbo", displayName: "Large Turbo",
                  tagline: "Best accuracy + fast. Recommended for most use.", size: "~632 MB", recommended: true),
        ModelInfo(id: "openai_whisper-small.en", displayName: "Small — English",
                  tagline: "Good accuracy, lower memory. English only.", size: "~200 MB", recommended: false),
        ModelInfo(id: "openai_whisper-tiny.en", displayName: "Tiny — English",
                  tagline: "Fastest, lightest. English only.", size: "~50 MB", recommended: false),
    ]

    var body: some View {
        Form {
            if !appState.isAccessibilityTrusted {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Accessibility access required")
                                .font(.callout).bold()
                            Text("Enable VoiceBar in System Settings, then restart the app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(spacing: 6) {
                            Button("Open Settings") {
                                appState.openAccessibilitySettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Restart VoiceBar") {
                                appState.restartApp()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let newVersion = appState.pendingUpdateVersion {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("VoiceBar \(newVersion) is available")
                                .font(.callout).bold()
                            Text("You're on v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"). Download the update to get the latest fixes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/anau219/VoiceBar/releases/latest")!)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                HStack(spacing: 14) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 52, height: 52)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("VoiceBar")
                            .font(.title3)
                            .fontWeight(.semibold)
                        statusLabel
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Hotkey") {
                LabeledContent("Shortcut") {
                    Button(isCapturingHotkey ? "Press a key..." : appState.hotkeyLabel) {
                        isCapturingHotkey = true
                        appState.unregisterHotkey()
                        HotkeyCapture.start { keyCode, modifiers in
                            appState.setHotkey(keyCode: keyCode, modifiers: modifiers)
                            isCapturingHotkey = false
                        }
                    }
                    .foregroundStyle(isCapturingHotkey ? .red : .primary)
                }
            }

            Section("General") {
                LaunchAtLogin.Toggle("Launch at login")

                Toggle("Show in Dock", isOn: Binding(
                    get: { appState.showInDock },
                    set: { appState.showInDock = $0 }
                ))

                LabeledContent("Updates") {
                    HStack {
                        if let msg = appState.updateCheckMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Button("Check now") {
                            Task { await appState.checkForUpdates(silent: false) }
                        }
                    }
                }
            }

            Section("Models") {
                if appState.downloadedModels.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No model downloaded")
                                .font(.callout).bold()
                            Text("Download Large Turbo to get started.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                ForEach(models, id: \.id) { model in
                    let isSelected = appState.selectedModel == model.id
                    let isDownloaded = appState.downloadedModels.contains(where: { $0.contains(model.id) })

                    HStack(alignment: .center, spacing: 10) {
                        Group {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if isDownloaded {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                            }
                        }
                        .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                    .font(.callout)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                if model.recommended {
                                    Text("Recommended")
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(model.tagline)  \(model.size)")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isDownloaded && !isSelected {
                            Button("Use") { Task { await appState.loadModel(model.id) } }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button("Delete") { appState.deleteModel(model.id) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .foregroundStyle(.red)
                        } else if !isDownloaded {
                            Button("Download") { Task { await appState.loadModel(model.id) } }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 620)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Link(destination: URL(string: "https://alchemyfy.com")!) {
                    Text("Made in Alchemyfy Lab")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Send Feedback") {
                    appState.openFeedbackWindow()
                }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch appState.status {
        case .idle:
            Label("Ready · Press \(appState.hotkeyLabel) to dictate", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading model... \(Int(progress * 100))%")
                    .font(.callout).foregroundStyle(.secondary)
                ProgressView(value: progress).frame(maxWidth: 200)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model...").font(.callout).foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        default:
            EmptyView()
        }
    }
}

// MARK: - Global Hotkey Capture

enum HotkeyCapture {
    private static var monitor: Any?

    static func start(onCapture: @escaping (Int, Int) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            let cleanMods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            onCapture(keyCode, Int(cleanMods.rawValue))
            stop()
            return nil
        }
    }

    static func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
