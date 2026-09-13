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


## Release Process

This app is distributed directly (outside the Mac App Store) **without** an Apple
Developer Program membership. Builds are ad hoc–signed ("Sign to Run Locally"), not
notarized. This document describes the full release cycle, from `Archive` to a
published build.

### Prerequisites (one-time setup)

- Xcode → Settings → Accounts: your Apple ID is added
- Target → Signing & Capabilities: Team is set to your free **Personal Team**
- "Automatically manage signing" is enabled (Xcode will use **Sign to Run Locally**)

### 1. Bump the version

- Update the version / build number in the target's General settings (or `Info.plist`)
- Add an entry to `CHANGELOG.md` describing what's new

## 2. Archive the build

- Set the run destination to **Any Mac (Apple Silicon, Intel)**
- `Product → Archive`
- Xcode Organizer opens automatically once the build finishes, with the new archive selected

## 3. Extract the .app from the archive

Skip `Distribute App → Direct Distribution` in Organizer — that flow requires a paid
Developer ID Application certificate, which this project doesn't have.

Instead, pull the built app straight out of the archive:

1. In Organizer, right-click the archive → **Show in Finder**
2. Right-click the `.xcarchive` file → **Show Package Contents**
3. Navigate to `Products/Applications/`
4. Copy `YourApp.app` to a working folder, e.g. `~/Desktop/release/`

### 4. Re-sign ad hoc (recommended)

Xcode's archive signature can carry references to the local build path. Re-signing
cleanly avoids signature issues after the app is moved/zipped:

```bash
codesign --force --deep -s - "YourApp.app"
```

### 5. Verify the signature

```bash
codesign --verify --deep --strict --verbose=2 "YourApp.app"
spctl -a -vvv "YourApp.app"
```

`spctl` will report the app as rejected/unnotarized — that's expected for this
distribution method. What matters is that `codesign --verify` reports no errors.

### 6. Package for distribution

**Zip** (simplest):

```bash
ditto -c -k --sequesterRsrc --keepParent "YourApp.app" "YourApp-1.2.0.zip"
```

**DMG** (nicer UX, drag-to-Applications window):

```bash
brew install create-dmg

create-dmg \
  --volname "YourApp" \
  --app-drop-link 450 120 \
  "YourApp-1.2.0.dmg" \
  "YourApp.app"
```

### 7. Publish the release

- Upload the `.zip` / `.dmg` to GitHub Releases (or your website)
- Tag the commit:

```bash
git tag v1.2.0
git push origin v1.2.0
```

- Paste the `CHANGELOG.md` entry into the release notes
- Include the Gatekeeper notice below in the release description / installation section

Use **GitHub Releases** to store and share built binaries — assets don't count
toward repo size and support files up to ~2 GB. Don't `git commit` the `.zip`/`.dmg`
directly into the repo.

Web UI: **Releases → Draft a new release**, attach the file, publish.

Or

```bash
gh release create v1.2.0 \
  YourApp-1.2.0.dmg \
  --title "v1.2.0" \
  --notes-file CHANGELOG.md
```

Since this repo is private, only collaborators with access can see and download it.


### 8. Gatekeeper notice for users

Because the app isn't notarized, macOS blocks it on first launch. Include something
like this in your install instructions:

> **macOS says the app "can't be opened" or is from an "unidentified developer"**
>
> This is expected — the app isn't notarized by Apple. To open it:
>
> 1. Try to open the app once (it will be blocked)
> 2. Go to **System Settings → Privacy & Security**
> 3. Scroll down — you'll see a message about the blocked app
> 4. Click **Open Anyway**, then confirm
>
> Alternatively, in Terminal:
>
> ```bash
> xattr -cr /Applications/YourApp.app
> ```

### Future: switching to notarized distribution

If you later enroll in the Apple Developer Program ($99/year), only steps 3–5 change:

- Signing & Capabilities → switch the certificate to **Developer ID Application**
- Organizer → use `Distribute App → Developer ID` instead of manually extracting the app
- Xcode / `notarytool` handles signing and notarization automatically
- Step 8 (Gatekeeper notice) can be removed — notarized apps open with no warnings
---
