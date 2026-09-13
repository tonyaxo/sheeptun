import Foundation

enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case inserting
    case error(String)

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .recording: return "Recording..."
        case .processing: return "Processing..."
        case .inserting: return "Inserting..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isActive: Bool {
        switch self {
        case .recording, .processing, .inserting: return true
        default: return false
        }
    }

    var systemImageName: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        case .inserting: return "text.cursor"
        case .error: return "exclamationmark.triangle"
        }
    }
}
