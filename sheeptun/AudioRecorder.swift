import Foundation
import AVFoundation

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineStartFailed(String)
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission denied."
        case .engineStartFailed(let r): return "Audio engine failed to start: \(r)"
        case .alreadyRecording: return "Already recording."
        case .notRecording: return "Not currently recording."
        }
    }
}

protocol AudioRecording: AnyObject {
    func startRecording(preferredDeviceUID: String?) async throws -> URL
    func stopRecording() async throws -> URL
    var isRecording: Bool { get }
    func availableInputDevices() -> [AudioInputDevice]
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

final class AudioRecorder: AudioRecording {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private(set) var isRecording = false

    func availableInputDevices() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func startRecording(preferredDeviceUID: String? = nil) async throws -> URL {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        outputFile = try AVAudioFile(forWriting: url, settings: format.settings)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.outputFile?.write(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            outputFile = nil
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }

        isRecording = true
        return url
    }

    func stopRecording() async throws -> URL {
        guard isRecording else { throw AudioRecorderError.notRecording }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let url = outputFile?.url
        outputFile = nil
        isRecording = false
        guard let url else { throw AudioRecorderError.notRecording }
        return url
    }
}
