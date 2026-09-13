# sheeptun

A native macOS menu bar dictation app. Hold a hotkey, speak in Russian, release — the transcribed text is inserted at the cursor in whatever app you were using.

All processing is local. No cloud, no accounts, no telemetry.

---

## Requirements

- macOS 15 (Sequoia) or later — required for the Speech framework's `SpeechAnalyzer` API
- Apple Silicon or Intel Mac with a supported speech-to-text model
- Xcode 16+ (to build)

---

## First launch

1. Build and run from Xcode (or install the exported app).
2. The app appears only in the menu bar — no Dock icon.
3. Open the menu and check **Permissions** — grant:
   - **Microphone** — click "Request Permission" in the menu
   - **Speech Recognition** — click "Request Permission" in the menu
   - **Accessibility** — click "Open System Settings" and enable sheeptun in Privacy & Security → Accessibility (required for the global hotkey and text insertion)
4. The model downloads automatically the first time you transcribe (~300 MB for Russian).

---

## Usage

| Action | Result |
|---|---|
| Hold **Right Option (⌥)** | Recording starts |
| Speak in Russian | Audio is captured locally |
| Release **Right Option (⌥)** | Recording stops, transcription runs |
| — | Text is inserted at the cursor in the active app |

The menu bar icon changes to indicate state:
- `mic` — Idle
- `mic.fill` (red) — Recording
- `waveform` (orange) — Processing
- `text.cursor` (blue) — Inserting
- `exclamationmark.triangle` (yellow) — Error

---

## Permissions explained

| Permission | Why |
|---|---|
| Microphone | Capture speech audio |
| Speech Recognition | Required by Apple's Speech framework even for on-device use |
| Accessibility | Global hotkey detection (CGEventTap) and Cmd+V simulation for text insertion |

---

## Architecture

```
sheeptunApp          — App entry point, MenuBarExtra scene
AppDelegate          — Wires all services together at launch

DictationSession     — Pipeline orchestrator (@MainActor)
  ├── AudioRecorder          — AVAudioEngine → temp CAF file
  ├── SpeechRecognitionEngine (protocol)
  │     └── AppleSpeechEngine  — SpeechAnalyzer + SpeechTranscriber (on-device, ru-RU)
  └── TextInserter (protocol)
        └── ClipboardTextInserter — save clipboard → Cmd+V → restore

HotkeyManager        — CGEventTap, Right Option key push-to-talk
PermissionsManager   — Microphone, Accessibility, SpeechRecognition
AppSettings          — UserDefaults-backed: hotkey, mic, locale, auto-insert
MenuBarView          — SwiftUI menu UI
```

### Replacing the STT engine (FluidAudio / Parakeet TDT v3)

The `SpeechRecognitionEngine` protocol is the only integration point:

```swift
protocol SpeechRecognitionEngine: AnyObject, Sendable {
    var isAvailable: Bool { get async }
    func prepare(locale: Locale) async throws
    func transcribe(audioURL: URL, locale: Locale) async throws -> String
}
```

To plug in FluidAudio + Parakeet TDT v3:
1. Add the FluidAudio Swift package to the project.
2. Create `FluidAudioParakeetEngine.swift` conforming to `SpeechRecognitionEngine`.
3. In `AppDelegate.init()`, replace `AppleSpeechEngine()` with your new engine.

---

## Building

```bash
# Debug build
xcodebuild -scheme sheeptun -configuration Debug build

# Release archive
xcodebuild -scheme sheeptun -configuration Release archive \
  -archivePath build/sheeptun.xcarchive
```

Or use **Product → Archive** in Xcode.

---

## Distributing (outside the App Store)

1. **Product → Archive**
2. In the Organizer: **Distribute App → Direct Distribution**
3. Choose **Developer ID** signing (requires a paid Apple Developer account)
4. Xcode notarizes the app automatically if you select "Upload to Apple's notarization service"
5. Export the `.app`, wrap in a `.dmg` or `.zip`

> **Note:** The app uses `CGEventTap` for the global hotkey, which requires the user to grant Accessibility permission in System Settings. This works correctly both sandboxed and unsandboxed. If you submit to the App Store, review Apple's guidelines on Accessibility entitlements first.

---

## Tests

```bash
xcodebuild test -scheme sheeptun -destination 'platform=macOS'
```

23 tests, 0 failures:
- Unit: state machines, settings, error handling, permissions
- Functional: full dictation pipeline with mocked audio/STT/insertion

---

## Settings (menu bar)

| Setting | Default |
|---|---|
| Hotkey | Right Option (⌥) |
| Microphone | System default |
| Auto-insert text | On |
| Language | Russian (ru-RU) |

---

## Privacy

- Speech audio is never sent to any server.
- Transcriptions are only inserted into the active app.
- Temporary audio files are deleted immediately after transcription.
- No analytics, no logging, no crash reporting.
