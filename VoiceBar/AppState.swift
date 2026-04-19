import Foundation
import SwiftUI
import WhisperKit
import HotKey
import AppKit

enum AppStatus: Equatable {
    case idle
    case downloading(progress: Double)
    case loading
    case recording
    case transcribing
    case error(message: String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .loading
    @Published var downloadedModels: [String] = []
    @Published var hotkeyLabel: String = "⌥Space"
    @Published var lastTranscription: String?
    @Published var streamingText: String = ""
    @Published var updateCheckMessage: String? = nil
    @Published var pendingUpdateVersion: String? = nil
    @Published var isAccessibilityTrusted: Bool = false

    @AppStorage("lastUpdateCheckTimestamp") private var lastUpdateCheckTimestamp: Double = 0

    @AppStorage("selectedModel") var selectedModel = "openai_whisper-large-v3-v20240930_turbo"
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode: Int = 49 // Space
    @AppStorage("hotkeyModifiers2") private var storedModifiers: Int = -1
    @AppStorage("showInDock") var showInDock: Bool = true {
        didSet { applyDockPolicy() }
    }

    private var hotkeyModifiers: Int {
        get {
            if storedModifiers == -1 {
                return Int(NSEvent.ModifierFlags.option.rawValue)
            }
            return storedModifiers
        }
        set { storedModifiers = newValue }
    }

    private var whisperKit: WhisperKit?
    private var audioRecorder = AudioRecorder()
    private var hotKey: HotKey?
    private var previousApp: NSRunningApplication?
    private var lastNonSelfApp: NSRunningApplication?
    private var mainWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var deferredPasteMonitor: Any?

    // Replace with your deployed Google Apps Script web app URL
    private let feedbackScriptURL = "https://script.google.com/macros/s/AKfycbzwQyLmqxS4NvB2ITnjHUHHoOKS6FNV-uIPbDE4f54NYFAFCLS9ea92SKKRApbv0wrZ/exec"

    // Escape key handling via CGEvent tap
    private var escapeTap: CFMachPort?
    private var escapeTapSource: CFRunLoopSource?
    private static weak var activeInstance: AppState?

    var menuBarIcon: String {
        switch status {
        case .recording: return "mic.fill"
        case .transcribing, .loading, .downloading: return "ellipsis.circle"
        case .error: return "exclamationmark.triangle"
        default: return "waveform"
        }
    }

    var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceBar/Models")
    }

    private var hasSetup = false
    private var pendingAccessibilityRestart = false

    func launchSetup() {
        setupIfNeeded()
        // If AX already trusted (normal relaunch after granting), open the window automatically.
        if AXIsProcessTrusted() {
            openMainWindow()
        }
        // If not trusted, the TCC dialog has the stage alone. User sees the banner
        // in the window and clicks "Restart VoiceBar" after enabling the toggle.
    }

    func openFeedbackWindow() {
        if let window = feedbackWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Send Feedback"
        window.contentView = NSHostingView(rootView: FeedbackView(appState: self))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.feedbackWindow = nil }
    }

    func submitFeedback(message: String, email: String, notify: Bool, appVersion: String, macOSVersion: String) async throws {
        guard let url = URL(string: feedbackScriptURL) else { throw URLError(.badURL) }

        let payload: [String: Any] = [
            "message": message,
            "email": email,
            "notify": notify,
            "appVersion": appVersion,
            "macOSVersion": macOSVersion,
            "model": selectedModel,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        Self.log("submitFeedback: sent successfully")
    }

    func openAccessibilitySettings() {
        pendingAccessibilityRestart = true
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        NSApplication.shared.terminate(nil)
    }

    func openMainWindow(activate: Bool = true) {
        if let window = mainWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "VoiceBar"
        window.minSize = NSSize(width: 380, height: 580)
        window.contentView = NSHostingView(rootView: MainView(appState: self))
        window.center()
        window.makeKeyAndOrderFront(nil)
        if activate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        mainWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.mainWindow = nil
        }
    }

    func setupIfNeeded() {
        guard !hasSetup else { return }
        hasSetup = true
        Self.activeInstance = self

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        isAccessibilityTrusted = AXIsProcessTrusted()

        // Poll every 2s until granted — then dismiss banner and open the main window
        Task {
            while !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(2))
            }
            await MainActor.run {
                self.isAccessibilityTrusted = true
                self.openMainWindow()
            }
        }

        applyDockPolicy()
        Task { await setup() }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: - Setup

    func setup() async {
        Self.log("setup started")
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        scanDownloadedModels()

        // Auto-restart after user grants accessibility in System Settings and returns to VoiceBar.
        // On Darwin 25+ with ad-hoc signing, AXIsProcessTrusted() never becomes true in the
        // running process — restart is required for the grant to take effect.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.pendingAccessibilityRestart else { return }
            self.pendingAccessibilityRestart = false
            // Give the system a moment to settle, then restart so TCC grant takes effect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.restartApp()
            }
        }

        // Dock icon click when all windows are closed
        NotificationCenter.default.addObserver(
            forName: .voiceBarReopen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openMainWindow()
        }

        // Track last non-VoiceBar frontmost app so previousApp is always meaningful
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastNonSelfApp = app
        }

        await loadModel(selectedModel)
        registerHotkey()

        // Silent update check once per day
        let oneDayAgo = Date().timeIntervalSince1970 - 86400
        if lastUpdateCheckTimestamp < oneDayAgo {
            await checkForUpdates(silent: true)
        }

        Self.log("setup complete")
    }

    // MARK: - Sound Feedback

    private func playSound(_ name: String) {
        DispatchQueue.global(qos: .userInteractive).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            task.arguments = ["/System/Library/Sounds/\(name).aiff"]
            try? task.run()
        }
    }

    // MARK: - Model Management

    func loadModel(_ variant: String) async {
        whisperKit = nil

        // Check if model is already on disk
        let modelPath = modelDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(variant)
        var localFolder: URL? = FileManager.default.fileExists(atPath: modelPath.path) ? modelPath : nil

        // Download phase — only if not already present
        if localFolder == nil {
            status = .downloading(progress: 0)
            do {
                localFolder = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: modelDirectory
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.status = .downloading(progress: progress.fractionCompleted)
                    }
                }
                scanDownloadedModels()
                Self.log("loadModel: download complete")
            } catch {
                Self.log("loadModel: download failed: \(error)")
                status = .error(message: "Download failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(5))
                if case .error = status { status = .idle }
                return
            }
        }

        // Load phase
        do {
            status = .loading
            let config = WhisperKitConfig(
                model: variant,
                downloadBase: modelDirectory,
                modelFolder: localFolder?.path,
                verbose: false,
                load: true
            )
            whisperKit = try await WhisperKit(config)
            selectedModel = variant
            scanDownloadedModels()
            status = .idle
            Self.log("loadModel: done")
        } catch {
            status = .error(message: "Model error: \(error.localizedDescription)")
            try? await Task.sleep(for: .seconds(5))
            if case .error = status { status = .idle }
        }
    }

    func deleteModel(_ variant: String) {
        let modelPath = modelDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(variant)
        try? FileManager.default.removeItem(at: modelPath)
        scanDownloadedModels()

        if selectedModel == variant {
            whisperKit = nil
            status = .error(message: "No model loaded")
        }
    }

    func scanDownloadedModels() {
        let modelsRoot = modelDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: nil
        ) else {
            downloadedModels = []
            return
        }
        downloadedModels = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
    }

    // MARK: - Hotkey

    func registerHotkey() {
        hotKey = nil
        guard let key = Key(carbonKeyCode: UInt32(hotkeyKeyCode)) else { return }
        let mods = NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiers))
            .intersection([.command, .option, .control, .shift])

        let hk = HotKey(key: key, modifiers: mods)
        hk.keyDownHandler = { [weak self] in
            Self.log("keyDownHandler fired!")
            Task { @MainActor in self?.toggleRecording() }
        }
        hotKey = hk
        updateHotkeyLabel()
    }

    func unregisterHotkey() { hotKey = nil }

    func setHotkey(keyCode: Int, modifiers: Int) {
        hotkeyKeyCode = keyCode
        let clean = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
            .intersection([.command, .option, .control, .shift])
        hotkeyModifiers = Int(clean.rawValue)
        registerHotkey()
    }

    private func updateHotkeyLabel() {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiers))
        if mods.contains(.command) { parts.append("⌘") }
        if mods.contains(.shift)   { parts.append("⇧") }
        if mods.contains(.option)  { parts.append("⌥") }
        if mods.contains(.control) { parts.append("⌃") }

        let keyNames: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space",
            96: "F5", 97: "F9", 98: "F6", 99: "F3", 100: "F8",
            101: "F10", 103: "F11", 105: "F13", 109: "F10",
            111: "F12", 118: "F4", 120: "F2", 122: "F1",
        ]
        parts.append(keyNames[hotkeyKeyCode] ?? "Key\(hotkeyKeyCode)")
        hotkeyLabel = parts.joined(separator: "")
    }

    // MARK: - Escape CGEvent Tap

    private func startEscapeTap() {
        guard AXIsProcessTrusted() else { return }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        escapeTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == 53 {
                    AppState.log("Escape detected via CGEvent tap")
                    Task { @MainActor in AppState.activeInstance?.cancelRecording() }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let tap = escapeTap else { return }
        escapeTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = escapeTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.log("startEscapeTap: enabled")
        }
    }

    private func stopEscapeTap() {
        if let tap = escapeTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = escapeTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        escapeTap = nil
        escapeTapSource = nil
        Self.log("stopEscapeTap: removed")
    }

    // MARK: - Recording & Transcription

    private func toggleRecording() {
        Self.log("toggleRecording called, status=\(status)")
        if status == .recording {
            stopRecordingAndTranscribe()
        } else if status == .idle {
            startRecording()
        }
    }

    private func startRecording() {
        guard whisperKit != nil else {
            Self.log("startRecording: no whisperKit")
            status = .error(message: "No model loaded")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        // If VoiceBar itself is frontmost (launch window open), fall back to last known app
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousApp = lastNonSelfApp
        } else {
            previousApp = frontmost
        }
        Self.log("Recording started, target: \(previousApp?.localizedName ?? "unknown")")
        do {
            stopDeferredPaste()
            try audioRecorder.startRecording()
            status = .recording
            streamingText = ""
            playSound("Tink")
            startEscapeTap()
        } catch {
            Self.log("Mic error: \(error)")
            status = .error(message: "Mic error: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard status == .recording else { return }
        stopEscapeTap()
        let audioURL = audioRecorder.stopRecording()
        Self.log("Recording stopped, audioURL=\(audioURL?.path() ?? "nil")")
        playSound("Pop")

        guard let audioURL else { status = .idle; return }

        status = .transcribing
        streamingText = ""
        Task { await transcribe(audioURL: audioURL) }
    }

    private func cancelRecording() {
        guard status == .recording else { return }
        Self.log("Recording cancelled by Escape")
        _ = audioRecorder.stopRecording()
        audioRecorder.cleanup()
        stopEscapeTap()
        playSound("Basso")
        streamingText = ""
        status = .error(message: "Recording cancelled")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if case .error = status { status = .idle }
        }
    }

    private func transcribe(audioURL: URL) async {
        Self.log("transcribe() called with \(audioURL.path())")

        guard let whisperKit else {
            Self.log("transcribe: no whisperKit")
            status = .error(message: "Model not loaded")
            audioRecorder.cleanup()
            return
        }

        do {
            let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path())
            let size = (attrs?[.size] as? Int) ?? 0
            Self.log("transcribe: audio file size = \(size) bytes")

            if size < 1000 {
                Self.log("transcribe: audio too small, skipping")
                status = .error(message: "Recording too short")
                audioRecorder.cleanup()
                try? await Task.sleep(for: .seconds(2))
                status = .idle
                return
            }

            let trimmedURL = AudioTrimmer.trimSilence(from: audioURL)
            let transcribeURL = trimmedURL ?? audioURL

            Self.log("transcribe: calling whisperKit.transcribe...")

            // Progress callback — updates streamingText token by token during transcription
            let results = try await whisperKit.transcribe(
                audioPath: transcribeURL.path(),
                callback: { [weak self] progress in
                    let text = progress.text.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        Task { @MainActor [weak self] in
                            self?.streamingText = text
                        }
                    }
                    return nil
                }
            )

            Self.log("transcribe: got \(results.count) results")
            let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            Self.log("transcribe: text = '\(text)'")

            audioRecorder.cleanup()
            if let trimmedURL, trimmedURL != audioURL {
                try? FileManager.default.removeItem(at: trimmedURL)
            }
            streamingText = ""

            guard !text.isEmpty else {
                status = .error(message: "No speech detected")
                try? await Task.sleep(for: .seconds(2))
                status = .idle
                return
            }

            lastTranscription = text  // stored clean, without trailing space
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text + " ", forType: .string)
            Self.log("transcribe: copied to clipboard")

            let targetApp = previousApp ?? lastNonSelfApp
            if let app = targetApp {
                Self.log("transcribe: reactivating \(app.localizedName ?? "unknown")")
                if #available(macOS 14.0, *) {
                    app.activate(from: NSRunningApplication.current)
                } else {
                    app.activate(options: .activateIgnoringOtherApps)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }

            Self.log("transcribe: inserting text")
            TextInserter.insertText(text + " ")
            startDeferredPaste(text: text, skipPID: targetApp?.processIdentifier ?? 0)
            status = .idle

        } catch {
            Self.log("transcribe ERROR: \(error)")
            streamingText = ""
            status = .error(message: "Transcription failed")
            audioRecorder.cleanup()
            try? await Task.sleep(for: .seconds(3))
            if case .error = status { status = .idle }
        }
    }

    // MARK: - Deferred Paste

    private func startDeferredPaste(text: String, skipPID: pid_t) {
        stopDeferredPaste()
        let myBundleID = Bundle.main.bundleIdentifier

        deferredPasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            let app = NSWorkspace.shared.frontmostApplication
            guard app?.bundleIdentifier != myBundleID else { return }
            guard app?.processIdentifier != skipPID else { return }
            self.stopDeferredPaste()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text + " ", forType: .string)
                TextInserter.simulatePaste(targetPID: pid)
                Self.log("deferredPaste: pasted to PID \(pid)")
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.stopDeferredPaste()
        }
    }

    private func stopDeferredPaste() {
        if let m = deferredPasteMonitor { NSEvent.removeMonitor(m) }
        deferredPasteMonitor = nil
    }

    // MARK: - Update Check

    func checkForUpdates(silent: Bool = false) async {
        if !silent { updateCheckMessage = "Checking..." }
        let repoAPI = "https://api.github.com/repos/anau219/VoiceBar/releases/latest"
        guard let url = URL(string: repoAPI) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)

            lastUpdateCheckTimestamp = Date().timeIntervalSince1970

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                if !silent { updateCheckMessage = "Could not fetch release info" }
                return
            }

            let latest = tagName.trimmingCharacters(in: .init(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            if isNewer(latest, than: current) {
                pendingUpdateVersion = latest
                if !silent { updateCheckMessage = "Version \(latest) available — see banner above" }
            } else {
                pendingUpdateVersion = nil
                if !silent { updateCheckMessage = "You're up to date (v\(current))" }
            }
        } catch {
            if !silent { updateCheckMessage = "Update check failed" }
        }
    }

    private func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let ai = i < av.count ? av[i] : 0
            let bi = i < bv.count ? bv[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    // MARK: - Logging

    nonisolated static func log(_ message: String) {
        #if DEBUG
        let line = "[\(Date())] \(message)\n"
        let path = "/tmp/voicebar_debug.log"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        #endif
    }
}
