import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "sheeptun", category: "DictationSession")

@MainActor
final class DictationSession: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var lastTranscription: String = ""
    @Published private(set) var modelReady: Bool = false

    private let audioRecorder: AudioRecording
    private let speechEngine: SpeechRecognitionEngine
    private let textInserter: TextInserting
    private let settings: AppSettings

    private var recordingURL: URL?
    private var activeTask: Task<Void, Never>?

    init(
        audioRecorder: AudioRecording,
        speechEngine: SpeechRecognitionEngine,
        textInserter: TextInserting,
        settings: AppSettings
    ) {
        self.audioRecorder = audioRecorder
        self.speechEngine = speechEngine
        self.textInserter = textInserter
        self.settings = settings
        Task { await self.warmUpEngine() }
    }

    private func warmUpEngine() async {
        log.info("Warming up speech engine for locale \(self.settings.locale.identifier)")
        do {
            try await speechEngine.prepare(locale: settings.locale)
            modelReady = true
            log.info("Speech engine ready")
        } catch {
            modelReady = false
            log.error("Speech engine warm-up failed: \(error)")
        }
    }

    func startDictation() async {
        guard state == .idle else {
            log.warning("startDictation called in non-idle state: \(self.state.displayName)")
            return
        }
        log.info("Starting dictation")
        do {
            let url = try await audioRecorder.startRecording(
                preferredDeviceUID: settings.selectedMicrophoneUID
            )
            recordingURL = url
            state = .recording
            log.info("Recording started → \(url.lastPathComponent)")
        } catch {
            log.error("Failed to start recording: \(error)")
            transition(to: .error(error.localizedDescription))
        }
    }

    func stopDictation() async {
        guard state == .recording else {
            log.warning("stopDictation called in non-recording state: \(self.state.displayName)")
            return
        }
        log.info("Stopping dictation, starting processing")
        state = .processing
        activeTask?.cancel()
        activeTask = Task { await processRecording() }
    }

    func cancelDictation() async {
        log.info("Cancelling dictation")
        activeTask?.cancel()
        if audioRecorder.isRecording {
            _ = try? await audioRecorder.stopRecording()
        }
        cleanupTempFile()
        transition(to: .idle)
    }

    private func processRecording() async {
        defer { cleanupTempFile() }
        do {
            let url = try await audioRecorder.stopRecording()
            log.info("Audio file ready: \(url.lastPathComponent)")

            if Task.isCancelled { transition(to: .idle); return }

            log.info("Starting transcription")
            let transcription = try await speechEngine.transcribe(
                audioURL: url,
                locale: settings.locale
            )
            log.info("Transcription result: \"\(transcription)\"")

            if Task.isCancelled { transition(to: .idle); return }

            lastTranscription = transcription
            state = .inserting

            if settings.autoInsertText {
                log.info("Inserting text")
                try await textInserter.insert(transcription)
                log.info("Text inserted")
            }

            transition(to: .idle)
        } catch is CancellationError {
            log.info("Processing cancelled")
            transition(to: .idle)
        } catch SpeechRecognitionError.emptyResult {
            log.info("Empty transcription — returning to idle")
            transition(to: .idle)
        } catch {
            log.error("Processing error: \(error)")
            transition(to: .error(error.localizedDescription))
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { transition(to: .idle) }
        }
    }

    private func transition(to newState: DictationState) {
        log.info("State: \(self.state.displayName) → \(newState.displayName)")
        state = newState
    }

    private func cleanupTempFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}
