import Foundation
import Combine
import OSLog
import UserNotifications

private let log = Logger(subsystem: "sheeptun", category: "DictationSession")

enum ModelDownloadState: Equatable {
    case downloading
    case ready
    case failed(String)

    var displayName: String {
        switch self {
        case .downloading: return "Downloading model…"
        case .ready: return "Model: Ready"
        case .failed: return "Download failed"
        }
    }

    var systemImage: String {
        switch self {
        case .downloading: return "arrow.trianglehead.2.clockwise"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

@MainActor
final class DictationSession: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var lastTranscription: String = ""
    @Published private(set) var modelDownloadState: ModelDownloadState = .downloading

    var modelReady: Bool { modelDownloadState == .ready }

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
        settings: AppSettings,
        skipWarmup: Bool = false
    ) {
        self.audioRecorder = audioRecorder
        self.speechEngine = speechEngine
        self.textInserter = textInserter
        self.settings = settings
        if skipWarmup {
            modelDownloadState = .ready
        } else {
            Task { await self.warmUpEngine() }
        }
    }

    private func warmUpEngine() async {
        modelDownloadState = .downloading
        log.info("Downloading/loading Parakeet TDT v3 for locale \(self.settings.locale.identifier)…")
        sendNotification(
            id: "model-downloading",
            title: "sheeptun: Downloading model",
            body: "Parakeet TDT v3 (~400 MB) is being downloaded. This happens once."
        )
        do {
            try await speechEngine.prepare(locale: settings.locale)
            modelDownloadState = .ready
            log.info("Speech engine ready")
            sendNotification(
                id: "model-ready",
                title: "sheeptun: Model ready",
                body: "Hold Right Option to start dictating."
            )
        } catch {
            modelDownloadState = .failed(error.localizedDescription)
            log.error("Speech engine warm-up failed: \(error)")
            sendNotification(
                id: "model-failed",
                title: "sheeptun: Download failed",
                body: "Open the menu bar icon to retry."
            )
        }
    }

    private func sendNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.warning("Notification '\(id)' not delivered: \(error)") }
        }
    }

    func retryModelDownload() async {
        guard case .failed = modelDownloadState else { return }
        await warmUpEngine()
    }

    func startDictation() async {
        guard state == .idle else {
            log.warning("startDictation called in non-idle state: \(self.state.displayName)")
            return
        }
        guard modelReady else {
            log.warning("startDictation called before model is ready")
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
                locale: settings.locale,
                languageFilterCode: settings.languageFilterCode
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
