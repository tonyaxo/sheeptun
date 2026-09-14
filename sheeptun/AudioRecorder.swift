import AVFoundation
import CoreAudio
import Foundation
import OSLog

// nonisolated: the prewarm runs off the main actor, and Logger is Sendable.
private nonisolated let log = Logger(subsystem: "sheeptun", category: "AudioRecorder")

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineStartFailed(String)
    case deviceBusy
    case deviceUnavailable
    case noAudioCaptured
    case writeFailed(String)
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission denied."
        case .engineStartFailed(let r): return "Audio engine failed to start: \(r)"
        case .deviceBusy: return "Microphone is busy — another app is using it."
        case .deviceUnavailable: return "The microphone is unavailable."
        case .noAudioCaptured: return "No audio captured — the microphone produced no data."
        case .writeFailed(let r): return "Could not write the recording: \(r)"
        case .alreadyRecording: return "Already recording."
        case .notRecording: return "Not currently recording."
        }
    }
}

protocol AudioRecording: AnyObject {
    func startRecording() async throws -> URL
    func stopRecording() async throws -> URL
    var isRecording: Bool { get }
}

/// Owns the output file for the real-time input tap. The tap callback runs on a dedicated
/// audio thread, so writes are serialized here and never touch MainActor-isolated state.
/// Write failures are recorded rather than dropped: a silently empty recording is
/// indistinguishable from a broken microphone by the time transcription rejects it.
private final class RecordingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFrameCount = 0
    private var firstError: Error?

    init(file: AVAudioFile) { self.file = file }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try file?.write(from: buffer)
            framesWritten += buffer.frameLength
        } catch {
            if firstError == nil { firstError = error }
        }
    }

    func snapshot() -> (frames: AVAudioFrameCount, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (framesWritten, firstError)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
}

final class AudioRecorder: AudioRecording {
    private let engine = AVAudioEngine()
    private var sink: RecordingSink?
    private var currentURL: URL?
    private var currentSampleRate: Double = 0
    private var prewarmTask: Task<Void, Never>?
    private(set) var isRecording = false

    /// Anything shorter than this is rejected up front: the speech engine needs 300 ms of
    /// audio and would otherwise fail with an error that says nothing about the microphone.
    private static let minimumDuration = 0.3

    /// The first audio use in a process costs about three seconds: CoreAudio enumerates audio
    /// components over XPC, brings up the sandbox helper, the HAL and the AUHAL, then negotiates
    /// stream formats. Paying that at launch keeps the first hotkey press as quick as every one
    /// after it — otherwise the user has already released the key by the time recording starts.
    /// Only the node and its format are touched, no IO is started, so the microphone stays off.
    func prewarm() {
        guard prewarmTask == nil else { return }
        let engine = self.engine
        prewarmTask = Task.detached(priority: .utility) {
            let format = engine.inputNode.outputFormat(forBus: 0)
            log.info("Audio path prewarmed: \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch")
        }
    }

    func startRecording() async throws -> URL {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        // Don't race the cold-start prewarm — both touch the same engine.
        await prewarmTask?.value

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            log.error("Input format unusable: \(format.channelCount) ch @ \(format.sampleRate) Hz")
            throw AudioRecorderError.deviceBusy
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let sink = RecordingSink(file: try AVAudioFile(forWriting: url, settings: format.settings))
        self.sink = sink
        currentURL = url
        currentSampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.write(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            teardownInput()
            sink.close()
            self.sink = nil
            currentURL = nil
            try? FileManager.default.removeItem(at: url)
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            throw Self.startFailure(from: error)
        }

        isRecording = true
        log.info("Recording started at \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch")
        return url
    }

    func stopRecording() async throws -> URL {
        guard isRecording else { throw AudioRecorderError.notRecording }

        // Tear down in this order: no tap callbacks can be in flight once the tap is removed,
        // so reading and closing the sink afterwards can never race a write.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        teardownInput()

        let (frames, writeError) = sink?.snapshot() ?? (0, nil)
        sink?.close()
        sink = nil
        isRecording = false

        let sampleRate = currentSampleRate
        let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
        log.info("Recorded \(frames) frames (\(duration, format: .fixed(precision: 2))s)")

        let url = currentURL
        currentURL = nil
        currentSampleRate = 0

        if let writeError {
            log.error("Recording write failed: \(writeError.localizedDescription, privacy: .public)")
            throw AudioRecorderError.writeFailed(writeError.localizedDescription)
        }
        guard duration >= Self.minimumDuration else {
            log.error("Recording too short: \(duration, format: .fixed(precision: 2))s")
            throw AudioRecorderError.noAudioCaptured
        }
        guard let url else { throw AudioRecorderError.notRecording }
        return url
    }

    /// Releases the input hardware after each recording. Without this the engine keeps the
    /// default-device aggregate (`CADefaultDeviceAggregate-<pid>-<n>`) alive, which both
    /// shows up as a phantom input device and leaves the next recording bound to a stale one.
    private func teardownInput() {
        engine.inputNode.auAudioUnit.deallocateRenderResources()
        engine.reset()
    }

    /// CoreAudio reports an in-use or unplugged device through a handful of OSStatus codes;
    /// map those to a message the user can act on instead of a raw error.
    private static func startFailure(from error: Error) -> AudioRecorderError {
        let code = (error as NSError).code
        switch code {
        case Int(kAudioHardwareNotRunningError),
             Int(kAudioHardwareIllegalOperationError),
             Int(kAudioDevicePermissionsError),
             -10851, -10863:
            return .deviceBusy
        case Int(kAudioHardwareBadDeviceError), Int(kAudioHardwareBadObjectError):
            return .deviceUnavailable
        default:
            return .engineStartFailed(error.localizedDescription)
        }
    }
}
