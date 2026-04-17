# VoiceBar — Claude Code Reference

## What It Is

Native macOS menu bar dictation app. Hold hotkey → speak → text inserts at cursor. No history, no AI rewrite, no themes. ~430 lines of Swift total. Deliberately minimal.

Lives in the system menu bar (no Dock icon by default). Entry point is `VoiceBarApp.swift`.

## Build & Run

```bash
# Build and deploy to /Applications (kill old instance first)
pkill -x VoiceBar; sleep 1
tccutil reset Accessibility com.voicebar.app
xcodebuild -scheme VoiceBar -configuration Debug -derivedDataPath build clean build
# IMPORTANT: rm -rf first — cp -R into an existing .app bundle creates a nested copy
rm -rf /Applications/VoiceBar.app && cp -R build/Build/Products/Debug/VoiceBar.app /Applications/VoiceBar.app
```

After launching, an orange banner in the main window will say "Accessibility access required" — click "Open Settings" and grant it. The banner disappears once granted. Text insertion won't work without this step.

**Why tccutil reset before deploy:** Ad-hoc signing (`--sign -`) produces a new signature on every build. macOS TCC treats a changed signature as a different app, revoking accessibility trust silently. Resetting before deploy ensures the new binary gets a clean prompt rather than silently denied state.

Open in Xcode: `open VoiceBar.xcodeproj`

## Architecture

```
VoiceBar/
  VoiceBarApp.swift     — App entry: MenuBarExtra (no Settings scene)
  AppDelegate.swift     — NSApplicationDelegate: Dock icon click → openMainWindow()
  AppState.swift        — Brain: WhisperKit lifecycle, recording, hotkey, escape tap, sounds
  AudioRecorder.swift   — AVAudioEngine → 16kHz mono float32 WAV
  AudioTrimmer.swift    — Trims leading/trailing silence before transcription
  TextInserter.swift    — AX API (primary), Cmd+V paste (fallback)
  MainView.swift        — Unified window: status, hotkey, general settings, model management
  MenuBarView.swift     — Menu bar dropdown UI
  Info.plist            — LSUIElement=true (no dock icon), mic usage description
  VoiceBar.entitlements — com.apple.security.device.audio-input, NO sandbox
  Assets.xcassets/      — Empty catalog (required by build)
  VoiceBar.icon/        — App icon (icon.json + icon voice bar.png, named VoiceBar.icon to match ASSETCATALOG_COMPILER_APPICON_NAME)
```

## Key Technical Decisions

**Text insertion:** AX API (`kAXSelectedTextAttribute` write) with verification → Cmd+V via `CGEvent postToPid` (or session broadcast if not trusted). Always copies to clipboard first so Cmd+V is reliable. CGEvent unicode (`keyboardSetUnicodeString`) was tried and removed — it always returned `true` even when target apps silently dropped events, blocking Cmd+V from ever firing.

**Escape to cancel:** `CGEvent.tapCreate` with `.cgSessionEventTap`. HotKey library can't handle bare Escape (requires modifier+key). Static callback + `activeInstance` weak ref pattern.

**Sound feedback:** `/usr/bin/afplay` via `Process` on background queue. NSSound conflicts with AVAudioEngine; AudioServicesPlaySystemSound had URL bugs.

**Silence trimming:** `AudioTrimmer` finds first/last sample above 0.01 threshold, adds 50ms lead-in / 100ms trail. Only trims if removing >0.5s. Improves WhisperKit accuracy on short recordings.

**Model auto-download:** Downloads `large-v3-turbo` (~632MB) on first launch. No setup screen. Progress shown in menu bar dropdown.

**Always-copy-to-clipboard:** Every transcription is copied to `NSPasteboard` before insertion as a manual fallback.

**Launch window:** `LaunchView` opens automatically on app start via `MenuBarExtra` label's `onAppear`. Created as `NSWindow` with `isReleasedWhenClosed = false` to prevent dealloc-during-action crashes. Cleaned up via `NSWindow.willCloseNotification`. Button closes via `NSApplication.shared.keyWindow?.close()` — do NOT route through AppState during close (causes crash).

**Target app tracking:** `AppState.lastNonSelfApp` is updated via `NSWorkspace.didActivateApplicationNotification`. In `startRecording()`, if VoiceBar itself is frontmost (e.g. main window open), falls back to `lastNonSelfApp` so text inserts into the correct app. Activation wait is 500ms to give the target app time to fully receive focus.

**Target app reactivation:** MUST use `activate(from: NSRunningApplication.current)` on macOS 14+ and `activate(options: .activateIgnoringOtherApps)` on macOS 13 and below. The bare deprecated `app.activate()` uses `ignoringOtherApps: false` and will silently fail to bring the target app to front when VoiceBar has focus — text insertion then fires into VoiceBar instead of the target. This was the root cause of insertion failures.

**Accessibility grant detection (Darwin 25+ / newer macOS):** After `tccutil reset`, granting via System Settings toggle does NOT make `AXIsProcessTrusted()` return true in the already-running process for ad-hoc signed binaries. The grant takes effect on relaunch. Detection flow: poll `AXIsProcessTrusted()` every 2s in a background `Task` started from `setupIfNeeded()`. When it returns true, set `isAccessibilityTrusted = true` (dismisses banner) and call `openMainWindow()` (auto-opens the window). On relaunch, `AXIsProcessTrusted()` returns true immediately at startup so `launchSetup()` opens the window directly.

**`applicationShouldHandleReopen` fires at startup when showInDock=true:** With `.regular` activation policy (Dock visible), macOS calls this delegate method at launch before any window is shown — `hasVisibleWindows = false` — which triggers our `.voiceBarReopen` notification and opens the main window. Guard with `readyForReopen = false` flag set to true in `applicationDidFinishLaunching` after a 1.5s delay.

**`cp -R` into existing `.app` creates nested bundle:** `cp -R src.app /Applications/dst.app` when dst already exists creates `/Applications/dst.app/src.app` (nested) instead of replacing. Always `rm -rf /Applications/VoiceBar.app` first, then `cp -R`.

**Deferred paste:** After transcription, a 3-second global `NSEvent` mouse monitor watches for a click in a different (non-VoiceBar, non-already-inserted) app and auto-pastes via Cmd+V. Cancelled on next recording or timeout.

**Text insertion chain:** AX API (`kAXSelectedTextAttribute`) with before/after verification → `simulatePaste` (Cmd+V via `postToPid` if trusted, session broadcast if not). AppState always writes to clipboard before calling `insertText`, so Cmd+V is a reliable fallback. CGEvent unicode helpers remain in `TextInserter.swift` but are NOT in the primary chain — they silently return `true` even when target apps drop the event.

## Dependencies (SPM)

| Package | Purpose |
|---------|---------|
| WhisperKit (Argmax) 0.12.0+ | On-device transcription via CoreML + Neural Engine |
| HotKey (soffes) 0.2.1+ | Global hotkey registration |
| LaunchAtLogin-Modern 1.1.0+ | SwiftUI toggle for login item |

## AppState Flow

```
launch → setupIfNeeded() → setup()
  → scanDownloadedModels()
  → loadModel(selectedModel)   ← downloads if needed
  → registerHotkey()

hotkey press → toggleRecording()
  → startRecording() → status = .recording
  → stopRecordingAndTranscribe() → status = .transcribing
  → transcribe() → TextInserter.insertText() → status = .idle
```

## Status Enum

```swift
enum AppStatus { idle | downloading(progress) | loading | recording | transcribing | error(message) }
```

Menu bar icon reflects status: `waveform` (idle), `mic.fill` (recording), `ellipsis.circle` (loading/transcribing), `exclamationmark.triangle` (error).

## Permissions Required

- Accessibility — text insertion + escape key interception. Prompt shown on first launch via `AXIsProcessTrustedWithOptions`.
- Microphone — recording. Declared in entitlements + Info.plist.
- No sandbox — required for CGEvent injection and AX access into other apps.

## Build Settings Notes

- `ASSETCATALOG_COMPILER_APPICON_NAME = VoiceBar` — must match the `.icon` folder name (`VoiceBar.icon`)
- `ENABLE_HARDENED_RUNTIME = YES` — required for notarization / distribution
- `ENABLE_APP_SANDBOX = NO` — required for CGEvent + AX access
- `LSUIElement = true` in Info.plist — hides Dock icon

## Common Issues

| Problem | Fix |
|---------|-----|
| Text insertion stops working after rebuild | `tccutil reset Accessibility com.voicebar.app` then relaunch |
| New `.swift` file not compiled | Add file reference + build file entry manually in `project.pbxproj` (PBXFileReference + PBXBuildFile + Sources list) |
| Icon shows as generic in Finder | Rebuild clean (`clean build`), then `killall Finder` |
| App won't open (Gatekeeper) | Right-click → Open on first launch (no Developer ID) |
| Launch window crashes on button press | Never call `window.close()` synchronously from within a SwiftUI button that owns the window — use `NSApplication.shared.keyWindow?.close()` from the view instead |

## Logging

Debug only (`#if DEBUG`). Writes to `/tmp/voicebar_debug.log`. Release builds produce no log.

## Planned / Future

### Permissions
- **Accessibility re-prompt on every launch** — Ad-hoc signing (`--sign -`) generates a new signature on every build/copy, invalidating TCC trust each time. Fix requires a stable Apple Developer ID certificate ($99/yr). Until then, `tccutil reset Accessibility com.voicebar.app` is the dev workaround. For personal use from `/Applications`, the prompt should only appear once per install (not on every launch) once signing is stable.

### Window & UX
- ~~**Unified main window**~~ — Done: `MainView.swift` replaces both `LaunchView` and `SettingsView`. Single Form with status, hotkey, general, model sections.
- ~~**"Open VoiceBar" menu bar item**~~ — Done: first item in dropdown, calls `appState.openMainWindow()`.
- ~~**Dock icon click opens main window**~~ — Done: `AppDelegate.applicationShouldHandleReopen` posts `.voiceBarReopen` notification → `AppState.openMainWindow()`.
- ~~**Resizable window**~~ — Done: `minWidth: 380, minHeight: 580`. Window is freely resizable.
- ~~**Larger status text**~~ — Done: "Ready" now uses green `checkmark.circle.fill` + `.primary` text.
- ~~**Accessibility banner**~~ — Done: `isAccessibilityTrusted` published bool + orange banner in MainView with "Open Settings" deeplink. Polls every 2s and auto-dismisses when granted.

### User Feedback & Communication
- ~~**Feedback window**~~ — Done: `FeedbackView.swift`. Form with message, optional email, "notify me of updates" toggle. Auto-collects app version, macOS version, model. Submits via POST to Google Apps Script → Google Sheets. Accessible from menu bar dropdown ("Send Feedback") and main window toolbar.
- ~~**User contact strategy**~~ — Done: optional email + notify toggle in feedback form.

### Audio / Transcription
- **Streaming v2:** Use `SFSpeechRecognizer` for live display while recording, replace with `large-v3-turbo` result on stop. `large-v3-turbo` runs at ~1× realtime — too slow for live streaming. See `VOICEBAR.md` for full options analysis.
- **Dual model:** `tiny.en` for live display + `large-v3-turbo` for final insert.
