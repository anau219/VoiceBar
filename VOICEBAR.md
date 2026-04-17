# VoiceBar — Project Reference

## Goal

A native macOS menu bar dictation app. Hold hotkey, speak, text appears at cursor. No history, no AI rewrite, no themes, no streaming panel. "Chrome extension energy" — invisible until needed, zero learning curve.

Built because macOS dictation is inaccurate, and every alternative is either paid, bloated, or both.

---

## Competitor Benchmarks

### Pindrop
- **Liked:** Clean UI, simple concept, local Whisper transcription
- **Disliked:** Text goes to clipboard instead of inserting at cursor (the bug that motivated VoiceBar). Feature creep: history, notes, dictionary, AI enhancement, themes, transcription panels

### SuperWhisper
- **Liked:** High-quality local transcription, polished
- **Disliked:** Paid ($8/mo or $96/yr). Heavy feature set — AI modes, custom vocabularies, 30+ languages panel. Way more than just dictation

### Spokenly
- **Liked:** Clean paste-at-cursor insertion that actually works. "Paste last transcription" menu bar button. Good onboarding
- **Disliked:** Uses GPT-4o mini (cloud, not local — privacy concern). Paid. Closed source

### FluidVoice (GPLv3, GitHub)
- **Liked:** Live streaming transcription. `TypingService.swift` revealed the key technique: `CGEvent.keyboardSetUnicodeString` + `postToPid` for direct text injection without clipboard pollution. Clean code to study
- **Disliked:** Uses Parakeet TDT v2 (not WhisperKit). Heavier than needed

### TypeWhisper (GitHub)
- **Liked:** `TextInsertionService.swift` showed AX verification pattern (`insertTextAtAndVerifyChange`). `HotkeyService.swift` showed `.cgSessionEventTap` for reliable paste simulation. Good reference for CGEvent tap patterns
- **Disliked:** AX API approach is fundamentally unreliable (returns success but apps silently ignore writes). Overly complex insertion chain

### Wispr Flow
- **Liked:** Polished UX
- **Disliked:** Paid. AI-heavy (rewrites, commands). Not just dictation

### MacWhisper
- **Liked:** Solid WhisperKit integration
- **Disliked:** Transcription-focused (file transcription, not live dictation). Not a menu bar utility

### Handy / Vocal-Prism
- **Disliked:** Feature-heavy, not focused on the single use case

---

## Architecture

```
VoiceBar/
  VoiceBarApp.swift        — App entry. MenuBarExtra + Settings scene
  AppState.swift           — Brain: WhisperKit lifecycle, recording flow, hotkey, escape tap, sounds
  AudioRecorder.swift      — AVAudioEngine → 16kHz mono float32 WAV
  AudioTrimmer.swift       — Trims leading/trailing silence from audio before transcription
  TextInserter.swift       — CGEvent unicode injection (primary), Cmd+V paste (fallback)
  MenuBarView.swift        — Menu bar dropdown: status, paste last, copy, settings, quit
  SettingsView.swift       — Hotkey capture, launch at login, model management
  Info.plist               — LSUIElement=true (no dock icon), mic usage description
  VoiceBar.entitlements    — com.apple.security.device.audio-input, NO sandbox
  Assets.xcassets/         — App icon (single 1024x1024 PNG)
```

### Dependencies (SPM)

| Package | Version | Purpose |
|---------|---------|---------|
| WhisperKit (Argmax) | 0.12.0+ | On-device transcription via CoreML + Neural Engine |
| HotKey (soffes) | 0.2.1+ | Global hotkey registration (modifier+key combos) |
| LaunchAtLogin-Modern | 1.1.0+ | One-line SwiftUI toggle for login item |

### Requirements
- macOS 14+ (Sonoma) — MenuBarExtra, WhisperKit compatibility
- Apple Silicon — WhisperKit uses CoreML + Neural Engine
- No sandbox — AXUIElement and CGEvent need to reach into other apps
- Accessibility permission — for text insertion and escape key interception
- Microphone permission — for recording

---

## Features & Why

### Text insertion via CGEvent unicode (`keyboardSetUnicodeString` + `postToPid`)
**Why:** Learned from FluidVoice. Injects text as keyboard input directly to the target app's PID. No clipboard pollution, no AX flakiness. For text >200 UTF-16 chars, falls back to Cmd+V (text is already on clipboard as backup).

**Why not AX API:** `AXUIElementSetAttributeValue` with `kAXSelectedTextAttribute` returns `.success` but many apps silently ignore the write. TypeWhisper handles this with verification + retry. We skip it entirely — CGEvent unicode is more reliable with less code.

### Always-copy-to-clipboard
**Why:** Every transcription is copied to `NSPasteboard` before insertion. If CGEvent injection fails for any reason, user can always Cmd+V manually. Zero-frustration fallback.

### Escape to cancel recording (CGEvent tap)
**Why:** Natural UX — Escape means "nevermind." Implemented via `CGEvent.tapCreate` with `.cgSessionEventTap` + `.tailAppendEventTap`. Swallows the Escape keypress so it doesn't reach the target app.

**Why not HotKey library:** HotKey requires modifier+key combos. Bare Escape (no modifiers) never fires. CGEvent tap is the same approach FluidVoice and TypeWhisper use for global key interception.

### Sound feedback (afplay)
**Why:** Audio confirmation that recording started/stopped/cancelled without looking at the screen. Tink on start, Pop on stop, Basso on cancel.

**Why afplay:** NSSound conflicts with AVAudioEngine (which is recording). AudioServicesPlaySystemSound had URL construction bugs. Running `/usr/bin/afplay` as a `Process` on a background thread is completely independent — works every time.

### Silence trimming (AudioTrimmer)
**Why:** Users often have a moment of silence before/after speaking. Trimming improves WhisperKit accuracy and reduces "no speech detected" false negatives. Finds first/last sample above threshold (0.01), adds 50ms lead-in / 100ms trail, only trims if removing >0.5s.

### Paste last transcription (menu bar)
**Why:** Learned from Spokenly. If text didn't land where expected, or user wants it again, one click re-inserts or copies to clipboard. Solves the "where did my text go?" anxiety.

### Toggle-mode hotkey (press to start, press to stop)
**Why:** Default ⌘⇧D. Press once to start recording, press again to stop and transcribe. Simpler than hold-to-record for longer dictations. Rebindable in Settings.

### Auto-download model on first launch
**Why:** No "pick a model" screen. Downloads `large-v3-turbo` (~632MB) automatically. Progress shown in menu bar dropdown. Power users can switch models in Settings > Models (collapsed by default).

### Conditional debug logging
**Why:** Writes to `/tmp/voicebar_debug.log` during development. Wrapped in `#if DEBUG` so release builds produce no log file.

---

## Key Technical Learnings

| Problem | Dead ends | Solution |
|---------|-----------|----------|
| Text insertion | AX API returns success but apps ignore writes | CGEvent `keyboardSetUnicodeString` + `postToPid` (from FluidVoice) |
| CGEvent source | `CGEventSource(stateID: .hidSystemState)` + `.cghidEventTap` failed | `nil` event source + `postToPid(pid)` targeting specific app |
| Global Escape key | `NSEvent.addGlobalMonitorForEvents` unreliable for bare keys; HotKey needs modifiers | `CGEvent.tapCreate` with static callback + `activeInstance` reference |
| Sound playback | NSSound conflicts with AVAudioEngine; AudioServicesPlaySystemSound URL bug | `afplay` via `Process` on background `DispatchQueue` |
| AX trust after rebuild | Ad-hoc signing invalidates trust on every binary change | `tccutil reset Accessibility com.voicebar.app` before each dev launch |
| New files not in build | xcodegen doesn't auto-detect new .swift files | `xcodegen generate` + restore entitlements (xcodegen clears them) |

---

## File Sizes

~430 lines of Swift total across all source files. Deliberately minimal.

---

## Distribution

1. Xcode: Product → Archive → Distribute App → Copy App
2. `zip -r VoiceBar.zip VoiceBar.app`
3. Share. Recipients right-click → Open on first launch (Gatekeeper)
4. Optional: $99/yr Apple Developer ID for notarization (no Gatekeeper warning)

---

## Streaming — Next Iteration

### Why streaming doesn't work with the current model

`large-v3-turbo` runs at roughly 1× real-time on Apple Silicon. For live streaming you need the model to process 1s of audio *faster* than 1s — ideally 5–10×. WhisperKit's `AudioStreamTranscriber` is wired up and the tokenizer issue is solved (`load: true` in config), but the model is too slow to produce visible results before the user stops speaking on short recordings.

Current workaround: WhisperKit's `transcribe()` progress callback shows partial text token-by-token during the transcription phase (after recording stops). Not true live streaming, but meaningful feedback.

### Options for v2

| Approach | How | Live accuracy | Final accuracy | Complexity |
|----------|-----|---------------|----------------|------------|
| **Dual model** | `tiny.en` for live display, `large-v3-turbo` for final insert | Low–medium | High | Medium — two WhisperKit instances |
| **Apple SFSpeechRecognizer** | Built-in OS streaming, zero download, ~5ms latency | Medium | — (replace with Whisper result) | Low — already on device |
| **WhisperKit tiny streaming** | Same `AudioStreamTranscriber`, switch to smaller model | Low–medium | — | Low — already wired |
| **Parakeet TDT** (NVIDIA) | 10–20× realtime, used by FluidVoice | Very high | Very high | High — not in WhisperKit, separate pipeline |

### Recommended v2 path

Use `SFSpeechRecognizer` (Apple's built-in, always on device, no download) for live display while recording. When the user stops, replace with the high-accuracy `large-v3-turbo` result. Best of both worlds:
- Zero added download size
- Instant live text (< 5ms latency)
- Final output is still Whisper-quality

`AudioStreamTranscriber` with `tiny.en` is the simpler alternative if accuracy of live text matters more than download size.
