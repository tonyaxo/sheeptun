import Testing
import Foundation
@testable import sheeptun

// MARK: - Test doubles

final class MockSpeechEngine: SpeechRecognitionEngine, @unchecked Sendable {
    var shouldFail = false
    var failWithEmpty = false
    var prepareCallCount = 0
    var transcribeCallCount = 0
    var transcriptionResult = "Привет мир"
    var lastLanguageFilterCode: String? = nil
    var languageFilterCodeCaptured = false

    var isAvailable: Bool { get async { true } }

    func prepare(locale: Locale) async throws {
        prepareCallCount += 1
    }

    func transcribe(audioURL: URL, locale: Locale, languageFilterCode: String?) async throws -> String {
        transcribeCallCount += 1
        lastLanguageFilterCode = languageFilterCode
        languageFilterCodeCaptured = true
        if shouldFail { throw SpeechRecognitionError.transcriptionFailed("mock error") }
        if failWithEmpty { throw SpeechRecognitionError.emptyResult }
        return transcriptionResult
    }
}

final class MockAudioRecorder: AudioRecording, @unchecked Sendable {
    var shouldFail = false
    var stopShouldFail = false
    private(set) var isRecording = false
    var startCallCount = 0
    var stopCallCount = 0
    var stubbedURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("mock.caf")

    func startRecording(preferredDeviceUID: String?) async throws -> URL {
        startCallCount += 1
        if shouldFail { throw AudioRecorderError.engineStartFailed("mock") }
        isRecording = true
        return stubbedURL
    }

    func stopRecording() async throws -> URL {
        stopCallCount += 1
        if stopShouldFail { throw AudioRecorderError.notRecording }
        isRecording = false
        return stubbedURL
    }

    func availableInputDevices() -> [AudioInputDevice] { [] }
}

final class MockTextInserter: TextInserting, @unchecked Sendable {
    var shouldFail = false
    var insertCallCount = 0
    var lastInsertedText: String?

    func insert(_ text: String) async throws {
        insertCallCount += 1
        lastInsertedText = text
        if shouldFail { throw TextInsertionError.failed("mock") }
    }
}

// MARK: - Helpers

/// Returns an AppSettings backed by a fresh, empty UserDefaults suite.
/// Prevents tests from reading or writing UserDefaults.standard,
/// so they cannot contaminate each other or the running app.
func makeIsolatedSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
}

@MainActor
func makeSession(
    recorder: MockAudioRecorder = MockAudioRecorder(),
    engine: MockSpeechEngine = MockSpeechEngine(),
    inserter: MockTextInserter = MockTextInserter(),
    settings: AppSettings? = nil
) -> DictationSession {
    DictationSession(
        audioRecorder: recorder,
        speechEngine: engine,
        textInserter: inserter,
        settings: settings ?? makeIsolatedSettings(),
        skipWarmup: true
    )
}

// MARK: - DictationState tests

@Suite("DictationState")
struct DictationStateTests {
    @Test("initial state is idle")
    @MainActor func initialStateIsIdle() async {
        let session = makeSession()
        #expect(session.state == .idle)
    }

    @Test("displayName matches state")
    func displayNames() {
        #expect(DictationState.idle.displayName == "Idle")
        #expect(DictationState.recording.displayName == "Recording...")
        #expect(DictationState.processing.displayName == "Processing...")
        #expect(DictationState.inserting.displayName == "Inserting...")
        #expect(DictationState.error("x").displayName == "Error: x")
    }

    @Test("isActive is true for active states")
    func isActive() {
        #expect(DictationState.recording.isActive == true)
        #expect(DictationState.processing.isActive == true)
        #expect(DictationState.inserting.isActive == true)
        #expect(DictationState.idle.isActive == false)
        #expect(DictationState.error("x").isActive == false)
    }
}

// MARK: - DictationSession state transitions

@Suite("DictationSession state transitions")
struct DictationSessionTransitionTests {
    @Test("startDictation transitions idle → recording")
    @MainActor func startTransition() async {
        let recorder = MockAudioRecorder()
        let session = makeSession(recorder: recorder)
        await session.startDictation()
        #expect(session.state == .recording)
        #expect(recorder.startCallCount == 1)
    }

    @Test("startDictation while already recording is a no-op")
    @MainActor func doubleStart() async {
        let recorder = MockAudioRecorder()
        let session = makeSession(recorder: recorder)
        await session.startDictation()
        await session.startDictation()
        #expect(recorder.startCallCount == 1)
    }

    @Test("startDictation failure transitions to error")
    @MainActor func startFailure() async {
        let recorder = MockAudioRecorder()
        recorder.shouldFail = true
        let session = makeSession(recorder: recorder)
        await session.startDictation()
        if case .error = session.state { } else {
            Issue.record("Expected .error state")
        }
    }

    @Test("stopDictation when not recording is a no-op")
    @MainActor func stopWhenIdle() async {
        let recorder = MockAudioRecorder()
        let session = makeSession(recorder: recorder)
        await session.stopDictation()
        #expect(recorder.stopCallCount == 0)
        #expect(session.state == .idle)
    }
}

// MARK: - Full pipeline tests

@Suite("Dictation pipeline")
struct DictationPipelineTests {
    @Test("happy path: idle → recording → idle with transcription")
    @MainActor func happyPath() async throws {
        let recorder = MockAudioRecorder()
        let engine = MockSpeechEngine()
        let inserter = MockTextInserter()
        let settings = makeIsolatedSettings()
        settings.autoInsertText = true

        let session = makeSession(recorder: recorder, engine: engine, inserter: inserter, settings: settings)
        await session.startDictation()
        #expect(session.state == .recording)

        await session.stopDictation()
        try await Task.sleep(for: .milliseconds(200))

        #expect(session.state == .idle)
        #expect(session.lastTranscription == engine.transcriptionResult)
        #expect(inserter.lastInsertedText == engine.transcriptionResult)
        #expect(engine.transcribeCallCount == 1)
        #expect(inserter.insertCallCount == 1)
    }

    @Test("empty transcription resolves to idle without error")
    @MainActor func emptyTranscription() async throws {
        let engine = MockSpeechEngine()
        engine.failWithEmpty = true
        let inserter = MockTextInserter()

        let session = makeSession(engine: engine, inserter: inserter)
        await session.startDictation()
        await session.stopDictation()
        try await Task.sleep(for: .milliseconds(200))

        #expect(session.state == .idle)
        #expect(inserter.insertCallCount == 0)
    }

    @Test("transcription failure transitions to error")
    @MainActor func transcriptionFailure() async throws {
        let engine = MockSpeechEngine()
        engine.shouldFail = true
        let inserter = MockTextInserter()

        let session = makeSession(engine: engine, inserter: inserter)
        await session.startDictation()
        await session.stopDictation()
        try await Task.sleep(for: .milliseconds(200))

        if case .error = session.state { } else {
            Issue.record("Expected .error state after transcription failure")
        }
        #expect(inserter.insertCallCount == 0)
    }

    @Test("text insertion failure transitions to error")
    @MainActor func insertionFailure() async throws {
        let inserter = MockTextInserter()
        inserter.shouldFail = true
        let settings = makeIsolatedSettings()
        settings.autoInsertText = true

        let session = makeSession(inserter: inserter, settings: settings)
        await session.startDictation()
        await session.stopDictation()
        try await Task.sleep(for: .milliseconds(200))

        if case .error = session.state { } else {
            Issue.record("Expected .error state after insertion failure")
        }
    }

    @Test("autoInsertText=false skips insertion")
    @MainActor func noAutoInsert() async throws {
        let inserter = MockTextInserter()
        let settings = makeIsolatedSettings()
        settings.autoInsertText = false

        let session = makeSession(inserter: inserter, settings: settings)
        await session.startDictation()
        await session.stopDictation()
        try await Task.sleep(for: .milliseconds(200))

        #expect(inserter.insertCallCount == 0)
        #expect(session.state == .idle)
    }

    @Test("cancel during recording resets to idle")
    @MainActor func cancelDuringRecording() async throws {
        let session = makeSession()
        await session.startDictation()
        await session.cancelDictation()
        #expect(session.state == .idle)
    }
}

// MARK: - Settings tests

@Suite("AppSettings")
struct AppSettingsTests {
    @Test("default hotkey is Right Option")
    func defaultHotkey() {
        let settings = makeIsolatedSettings()
        #expect(settings.hotkey.keyCode == 61)
    }

    @Test("default locale is Russian")
    func defaultLocale() {
        let settings = makeIsolatedSettings()
        #expect(settings.locale.identifier.hasPrefix("ru"))
    }

    @Test("autoInsertText defaults to true")
    func defaultAutoInsert() {
        let settings = makeIsolatedSettings()
        #expect(settings.autoInsertText == true)
    }

    @Test("HotkeyConfig displayString for Right Option")
    func hotkeyDisplay() {
        let config = HotkeyConfig.defaultConfig
        #expect(config.displayString == "⌥ Right Option")
    }
}

// MARK: - Language filter tests

@Suite("Language filter")
struct LanguageFilterTests {
    @Test("default languageFilterCode is nil")
    func defaultIsNil() {
        let settings = makeIsolatedSettings()
        #expect(settings.languageFilterCode == nil)
    }

    @Test("availableLanguageFilters is non-empty and well-formed")
    func filtersWellFormed() {
        let filters = AppSettings.availableLanguageFilters
        #expect(!filters.isEmpty)
        #expect(filters.allSatisfy { !$0.code.isEmpty && !$0.name.isEmpty })
        #expect(filters.contains { $0.code == "ru" })
        #expect(filters.contains { $0.code == "en" })
        #expect(filters.contains { $0.code == "el" })
    }

    @Test("languageFilterCode is forwarded to speech engine")
    @MainActor func filterForwarded() async throws {
        let engine = MockSpeechEngine()
        let settings = makeIsolatedSettings()
        settings.languageFilterCode = "fr"

        let session = makeSession(engine: engine, settings: settings)
        await session.startDictation()
        await session.stopDictation()
        try await Task.sleep(for: .milliseconds(200))

        #expect(engine.languageFilterCodeCaptured)
        #expect(engine.lastLanguageFilterCode == "fr")
    }

    @Test("nil languageFilterCode is forwarded as nil")
    @MainActor func nilFilterForwarded() async throws {
        let engine = MockSpeechEngine()
        let settings = makeIsolatedSettings()
        settings.languageFilterCode = nil

        let session = makeSession(engine: engine, settings: settings)
        await session.startDictation()
        await session.stopDictation()
        try await Task.sleep(for: .milliseconds(200))

        #expect(engine.languageFilterCodeCaptured)
        #expect(engine.lastLanguageFilterCode == nil)
    }
}

// MARK: - SpeechRecognitionError tests

@Suite("SpeechRecognitionError")
struct SpeechRecognitionErrorTests {
    @Test("error descriptions are non-empty")
    func descriptions() {
        let errors: [SpeechRecognitionError] = [
            .engineUnavailable,
            .modelNotInstalled,
            .transcriptionFailed("test"),
            .emptyResult
        ]
        for error in errors {
            #expect(!(error.errorDescription?.isEmpty ?? true))
        }
    }
}

// MARK: - PermissionsManager tests

@Suite("PermissionsManager")
struct PermissionsManagerTests {
    @Test("allGranted is false when any permission is not granted")
    @MainActor func allGrantedFalse() {
        let mgr = PermissionsManager()
        #expect(mgr.allGranted == false)
    }

    @Test("summary lists missing permissions")
    @MainActor func summaryListsMissing() {
        let mgr = PermissionsManager()
        #expect(!mgr.summary.isEmpty)
    }
}
