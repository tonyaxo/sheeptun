import Foundation

/// Protocol isolating the speech-to-text engine so implementations can be swapped
/// (e.g. Apple Speech → FluidAudio + Parakeet TDT v3).
protocol SpeechRecognitionEngine: AnyObject, Sendable {
    /// Returns `true` when the engine is ready to transcribe.
    var isAvailable: Bool { get async }

    /// Downloads or prepares any required model assets.
    func prepare(locale: Locale) async throws

    /// Transcribes the audio at `url` and returns the plain-text result.
    /// Pass `languageFilterCode` (BCP-47 like "ru", "en") to restrict tokens to that language's
    /// script. Pass `nil` to disable filtering — best for mixed-language speech.
    func transcribe(audioURL: URL, locale: Locale, languageFilterCode: String?) async throws -> String
}

enum SpeechRecognitionError: LocalizedError {
    case engineUnavailable
    case modelNotInstalled
    case transcriptionFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .engineUnavailable: return "Speech recognition engine is not available on this device."
        case .modelNotInstalled: return "Speech recognition model is not installed."
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        case .emptyResult: return "No speech detected."
        }
    }
}
