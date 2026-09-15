# sheeptun

A native macOS menu bar dictation app. Hold a hotkey, speak in Russian, release — the transcribed text is inserted at the cursor in whatever app you were using.

All processing is local. No cloud, no accounts, no telemetry.

## Known issues

- **A newly installed build can lose its permissions.** macOS ties granted permissions to an
  app's code signature, and an ad hoc signature changes with every build — so a fresh build
  asks for the microphone again and may have to be re-added under Accessibility. Signing with
  a certificate you reuse avoids this; see
  [Permissions and ad-hoc signatures](#5a-permissions-and-ad-hoc-signatures).

- **There is no microphone picker.** Dictation always records from the system default input,
  which you choose in System Settings → Sound. If the default device produces no audio,
  dictation reports "No audio was captured" instead of transcribing.

---

## Requirements

- macOS 15 (Sequoia) or later — required for the Speech framework's `SpeechAnalyzer` API
- Apple Silicon or Intel Mac with a supported speech-to-text model
- Xcode 16+ (to build)

---

## First launch

1. Build and run from Xcode, or install the exported app — see [Building](#building).
2. The app lives in the menu bar only — no Dock icon.
3. Grant the two permissions it asks for on first launch:
   - **Microphone** — the system prompt appears by itself; click Allow.
   - **Accessibility** — the app shows the system prompt; open System Settings from it and
     enable sheeptun under Privacy & Security → Accessibility. This is what the global hotkey
     and text insertion need. The hotkey starts working within about a second of the grant —
     no menu action required.
4. The speech model (~400 MB) downloads on first launch. The menu shows the progress and a
   notification arrives once it is ready; dictation works after that.

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

### Launch at login, and what a launch agent would take

The app can register itself as a login item through `SMAppService.mainApp`, and only when the user
switches **Launch at Login** on in the menu — it never registers itself on its own initiative. The
state is always read back from `SMAppService` rather than cached, because login items can be changed
in System Settings at any time.

A login item starts the app at login and does nothing else. The system may also terminate a menu bar
app mid-session: when the startup disk runs low, `cache_delete` asks RunningBoard to kill it to purge
the app's container caches. That leaves no crash report — only a `launchd` record:

```
exited with exit reason (namespace: 15 code: 0xbaddd15c) - OS_REASON_RUNNINGBOARD
explanation: CacheDeleteAppContainerCaches requesting termination assertion
```

Nothing brings the app back until the next login. If that ever needs fixing, the mechanism is a
launch agent, and it has to be built like this:

1. **A helper target, not this app.** An agent whose program is the app's own executable starts a
   *second copy* of the app instead of adopting the running one — an agent is meant to be a separate
   faceless process. So the supported shape is a small UI-less helper target with its own binary
   inside the bundle, whose only job is to relaunch the app.
2. **A plist inside the bundle** at `Contents/Library/LaunchAgents/<label>.plist`, put there by a
   Copy Files build phase (destination *Wrapper*, subpath `Contents/Library/LaunchAgents`). The
   `Label` must match the file name, and `BundleProgram` points at the helper, relative to the bundle.
3. **Registration** with `SMAppService.agent(plistName:)`. It appears in System Settings under
   *Allow in the Background*, separately from *Open at Login* — so register either the agent or the
   login item, never both, or the app starts twice and the user gets two switches for one thing.
4. **Keys that matter:** `RunAtLoad` to start it at login; `KeepAlive` as
   `{ SuccessfulExit = false }` so Quit in the menu stays quit while a system kill is undone;
   `ThrottleInterval` so a relaunch loop cannot fight whatever killed the app; `ProcessType` of
   `Interactive`; `LimitLoadToSessionType` of `Aqua`; and `AssociatedBundleIdentifiers` so System
   Settings names the app instead of a bare label.

Until auto-restart is genuinely needed, the login item is the whole story — and free disk space is
what actually keeps the app alive.

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

`build.sh` covers the whole cycle — compile, test, archive, sign, verify and package.
It needs nothing but Xcode's command line tools; `create-dmg` is required only for `--dmg`.

```bash
./build.sh test                                        # run the unit tests
./build.sh build                                       # compile (Debug)
./build.sh build release                               # compile (Release)
./build.sh release                                     # test -> archive -> sign -> verify -> package
./build.sh release --no-test                           # same, without the test run
./build.sh release --dmg                               # also produce a .dmg
./build.sh release --identity "SheepTun Local Signing" # sign with a certificate instead of ad hoc
./build.sh clean                                       # remove build/
./build.sh --help
```

### Find identity to sign

```bash
security find-identity -v -p codesigning
```

### What `release` does

1. Runs the unit tests (skip with `--no-test`)
2. `xcodebuild archive` into `build/SheepTun.xcarchive` — no Organizer involved
3. Copies the app out of the archive to `build/dist/SheepTun.app`
4. Extracts the entitlements from the archived bundle and re-signs with them, nested code first
5. Verifies the signature and asserts `app-sandbox`, `device.audio-input` and
   `network.client` are still present — the build fails if any entitlement was lost
6. Packages `SheepTun-<version>.zip`, and a `.dmg` with `--dmg`, taking the version from
   `MARKETING_VERSION`
7. Prints the `gh release create` command for publishing

### Output

```
build/
├── logs/                  # full xcodebuild output, surfaced only on failure
├── SheepTun.xcarchive
├── SheepTun.entitlements  # extracted from the archive, used for re-signing
└── dist/
    ├── SheepTun.app
    ├── SheepTun-1.0.zip
    └── SheepTun-1.0.dmg
```

`build/` is gitignored. A release run looks like this:

```
==> Releasing SheepTun 1.0
==> Archiving (Release)
    SheepTun.xcarchive
==> Extracting the app from the archive
    sheeptun.app → SheepTun.app
==> Re-signing (identity: -)
    entitlements saved to SheepTun.entitlements
    signed SheepTun.app
==> Verifying signature and entitlements
    SheepTun.app: valid on disk
    SheepTun.app: satisfies its Designated Requirement
    com.apple.security.app-sandbox ✓
    com.apple.security.device.audio-input ✓
    com.apple.security.network.client ✓
    spctl: SheepTun.app: rejected
==> Packaging
    SheepTun-1.0.zip (19M)
==> Done
```

`spctl: rejected` is expected — the app is not notarized. See
[Gatekeeper notice for users](#8-gatekeeper-notice-for-users).

### Signing identity

The default identity is ad hoc (`-`). An ad-hoc signature changes on every build, so macOS
treats each build as a brand-new app and previously granted Microphone and Accessibility
permissions stop applying. Pass `--identity` with a self-signed certificate you reuse to
keep those grants stable across builds — see
[Permissions and ad-hoc signatures](#5a-permissions-and-ad-hoc-signatures).

### Without the script

```bash
xcodebuild -scheme sheeptun -destination 'platform=macOS' -configuration Release build
xcodebuild test -scheme sheeptun -destination 'platform=macOS' -only-testing:sheeptunTests
```

`swift build` cannot build this app: SwiftPM has no `.app` bundle product type, does not
compile the asset catalog, and does not sign or apply entitlements. FluidAudio is consumed
as a SwiftPM dependency inside the Xcode project.

---

## Tests

```bash
./build.sh test
```

28 tests, 0 failures:
- Unit: state machines, settings, error handling, permissions
- Functional: full dictation pipeline with mocked audio/STT/insertion, including the
  failure paths (no audio captured, transcription failure, no speech detected)

---

## Settings (menu bar)

| Setting | Default |
|---|---|
| Hotkey | Right Option (⌥) |
| Auto-insert text | On |
| Language | Russian (ru-RU) |
| Language filter | None (the model picks the script per token) |

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

Steps 2–7 are what `./build.sh release` automates (see [Building](#building)); they are
documented here as the manual path, and to explain what the script does.

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

### 4. Re-sign — and keep the entitlements

**Never run `codesign --force --deep -s - "SheepTun.app"` on its own.** Signing without
`--entitlements` **strips every entitlement** from the bundle: App Sandbox, microphone
access and network access all silently disappear, and the app you ship stops matching the
app you built and tested.

Extract the entitlements first, then re-sign with them (inside-out: nested code before the
bundle, since `--deep` is not a reliable way to sign an app for distribution):

```bash
# 1. Save the entitlements Xcode generated
codesign -d --entitlements SheepTun.entitlements --xml "SheepTun.app"

# 2. Sign nested code first
find "SheepTun.app/Contents/Frameworks" -depth 1 -print0 2>/dev/null |
  xargs -0 -I {} codesign --force --options runtime -s - "{}"

# 3. Sign the app itself, with entitlements and Hardened Runtime
codesign --force --options runtime \
  --entitlements SheepTun.entitlements \
  -s - "SheepTun.app"
```

If re-signing isn't necessary, the safest option is to ship the archive's app untouched.

### 5. Verify the signature *and* the entitlements

```bash
codesign --verify --strict --verbose=2 "SheepTun.app"
codesign -d --entitlements - "SheepTun.app"
spctl -a -vvv "SheepTun.app"
```

The entitlements dump must still list `com.apple.security.app-sandbox`,
`com.apple.security.device.audio-input` and `com.apple.security.network.client`. If it
prints nothing, step 4 wiped them — do not ship that build.

`spctl` will report the app as rejected/unnotarized — that's expected for this
distribution method. What matters is that `codesign --verify` reports no errors.

### 5a. Permissions and ad-hoc signatures

macOS keys granted permissions (Microphone, Accessibility) to the app's code signature.
An ad-hoc signature changes on **every** rebuild, so every repackaged build looks like a
brand-new app to the system: earlier grants no longer apply, and a stale entry can sit in
System Settings pointing at the old signature.

To keep grants stable across builds, sign with a **self-signed certificate** you reuse
(Keychain Access → Certificate Assistant → Create a Certificate, type "Code Signing"),
and pass its name instead of `-`:

```bash
codesign --force --options runtime --entitlements SheepTun.entitlements \
  -s "SheepTun Local Signing" "SheepTun.app"
```

If permissions still look stuck after installing a new build, reset them once:

```bash
tccutil reset Microphone local.project.sheeptun
tccutil reset Accessibility local.project.sheeptun
```

### 6. Package for distribution

**Zip** (simplest):

```bash
ditto -c -k --sequesterRsrc --keepParent "SheepTun.app" "SheepTun-1.2.0.zip"
```

**DMG** (nicer UX, drag-to-Applications window):

```bash
brew install create-dmg

create-dmg \     
  --volname "SheepTun" \
  --app-drop-link 450 120 \
  "SheepTun-0.1.0.dmg" \
  "SheepTun.app"
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
