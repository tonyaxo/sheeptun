import FluidAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "sheeptun", category: "FluidAudioParakeetEngine")

final class FluidAudioParakeetEngine: SpeechRecognitionEngine, @unchecked Sendable {
    private var asrManager: AsrManager?

    var isAvailable: Bool {
        get async { asrManager != nil }
    }

    func prepare(locale: Locale) async throws {
        guard asrManager == nil else {
            log.info("Model already loaded, skipping prepare")
            return
        }
        log.info("Downloading/loading Parakeet TDT v3...")
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            asrManager = AsrManager(config: .default, models: models)
            log.info("Parakeet TDT v3 ready")
        } catch {
            log.error("Failed to load Parakeet TDT v3: \(error)")
            throw SpeechRecognitionError.transcriptionFailed("Model load failed: \(error.localizedDescription)")
        }
    }

    func transcribe(audioURL: URL, locale: Locale, languageFilterCode: String?) async throws -> String {
        if asrManager == nil {
            try await prepare(locale: locale)
        }
        guard let asrManager else {
            throw SpeechRecognitionError.modelNotInstalled
        }

        let language = languageFilterCode.flatMap { Language(rawValue: $0) }
        log.info("Running Parakeet TDT v3 transcription: \(audioURL.lastPathComponent), filter: \(language?.rawValue ?? "none")")
        let result: ASRResult
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: 2)
            result = try await asrManager.transcribe(audioURL, decoderState: &decoderState, language: language)
        } catch {
            log.error("Transcription failed: \(error)")
            throw SpeechRecognitionError.transcriptionFailed(error.localizedDescription)
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info("Transcription result: \"\(text)\"")
        guard !text.isEmpty else {
            throw SpeechRecognitionError.emptyResult
        }
        return text
    }
}
