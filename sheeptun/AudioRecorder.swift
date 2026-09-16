import AVFoundation
import CoreAudio
import Foundation
import OSLog

// nonisolated: the prime and the CoreAudio device listener both run off the main actor,
// and Logger is Sendable.
private nonisolated let log = Logger(subsystem: "sheeptun", category: "AudioRecorder")

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineStartFailed(String)
    case deviceBusy
    case deviceUnavailable
    case noAudioCaptured
    case inputDeviceChanged
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
        case .inputDeviceChanged: return "The microphone changed while recording — press the hotkey again."
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

/// The slice of recorder state that callbacks reach from off the caller's thread: the
/// CoreAudio device listener and the engine's configuration-change observer. Both can fire
/// after the recording they belong to has finished, so disruption is generation-stamped
/// and a late callback is dropped rather than applied to whatever replaced it.
///
/// Internal rather than private so the generation stamping can be tested directly: it is
/// the one part of the recorder that is pure logic rather than CoreAudio behaviour.
final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var disruptedGeneration: Int?
    private var primedDevice: AudioDeviceID?
    private var recording = false

    /// Opens a new generation, retiring every callback still holding the previous one.
    func beginGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        disruptedGeneration = nil
        recording = true
        return generation
    }

    func endGeneration() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        recording = false
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    /// Returns false when the callback belongs to a retired generation.
    func markDisrupted(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return false }
        disruptedGeneration = generation
        return true
    }

    func wasDisrupted(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disruptedGeneration == generation
    }

    /// Swaps in the newly primed device, returning false when it was already primed.
    func prime(device: AudioDeviceID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard device != primedDevice else { return false }
        primedDevice = device
        return true
    }
}

final class AudioRecorder: AudioRecording {
    /// A fresh engine per recording. A long-lived one stays bound to the input device it
    /// first saw: once the default input changes — AirPods connecting is the usual way —
    /// it keeps reporting the old device's format and its tap goes silent, so every later
    /// dictation captures nothing for the rest of the process. `reset()` does not undo
    /// that; per `AVAudioEngine.h` it only silences reverb and delay tails, removing no
    /// taps and re-reading no hardware formats.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var sink: RecordingSink?
    private var currentURL: URL?
    private var currentSampleRate: Double = 0
    private var currentGeneration = 0

    private let state = CaptureState()

    /// Serializes priming against itself and against the start of a recording, so no two
    /// code paths negotiate the audio path at the same time.
    private let primeQueue = DispatchQueue(label: "sheeptun.AudioRecorder.prime")
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var pendingPrime: DispatchWorkItem?

    var isRecording: Bool { state.isRecording }

    /// Anything shorter than this is rejected up front: the speech engine needs 300 ms of
    /// audio and would otherwise fail with an error that says nothing about the microphone.
    private static let minimumDuration = 0.3

    /// CoreAudio reports one device switch as a burst of notifications. Re-priming per
    /// notification would renegotiate the audio path repeatedly while AirPods are still
    /// settling, so the work is coalesced into a single pass.
    private static let deviceChangeDebounce: DispatchTimeInterval = .milliseconds(250)

    deinit {
        pendingPrime?.cancel()
        if let deviceListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, primeQueue, deviceListener
            )
        }
    }

    // MARK: - Priming

    /// The first audio use in a process costs about three seconds: CoreAudio enumerates audio
    /// components over XPC, brings up the sandbox helper, the HAL and the AUHAL, then negotiates
    /// stream formats. Paying that at launch keeps the first hotkey press as quick as every one
    /// after it — otherwise the user has already released the key by the time recording starts.
    /// Only a throwaway node and its format are touched, no IO is started, so the microphone
    /// stays off.
    func prewarm() {
        installDeviceListener()
        primeQueue.async { [weak self] in self?.prime(reason: "launch") }
    }

    /// Negotiates the current input device's format ahead of the next hotkey press. Run at
    /// launch and again whenever the default input changes, because the component and HAL
    /// warm-up is process-wide but format negotiation is per device.
    private func prime(reason: String) {
        guard !state.isRecording else { return }
        guard state.prime(device: Self.defaultInputDevice()) else {
            log.debug("Input device already primed, skipping prime (\(reason, privacy: .public))")
            return
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.auAudioUnit.deallocateRenderResources()
        log.info(
            "Audio path primed (\(reason, privacy: .public)): \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch"
        )
    }

    /// Watches the system default input rather than the engine's own configuration-change
    /// notification: that notification is scoped to a running engine, so on its own it never
    /// fires for the case that actually breaks dictation — the device changing between
    /// recordings, while no engine exists.
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.schedulePrime(reason: "default-input-changed")
        }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, primeQueue, listener
        )
        guard status == noErr else {
            log.error("Could not observe the default input device: OSStatus \(status)")
            return
        }
        deviceListener = listener
        log.info("Observing the default input device")
    }

    /// Called on `primeQueue`, which is also where the work item runs, so `pendingPrime`
    /// needs no further synchronization.
    private func schedulePrime(reason: String) {
        pendingPrime?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.prime(reason: reason) }
        pendingPrime = item
        primeQueue.asyncAfter(deadline: .now() + Self.deviceChangeDebounce, execute: item)
    }

    // MARK: - Recording

    func startRecording() async throws -> URL {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        // Don't race an in-flight prime — both negotiate the same audio path.
        await withCheckedContinuation { continuation in
            primeQueue.async { continuation.resume() }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // Read from the engine that is about to record, never from a cached one: CoreAudio
        // completes a device switch asynchronously, and a format snapshot taken before it
        // lands describes the previous device. Installing a tap with a mismatched format
        // raises an Objective-C exception that Swift cannot catch.
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            log.error("Input format unusable: \(format.channelCount) ch @ \(format.sampleRate) Hz")
            throw AudioRecorderError.deviceBusy
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let sink = RecordingSink(file: try AVAudioFile(forWriting: url, settings: format.settings))
        let generation = state.beginGeneration()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.write(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            inputNode.auAudioUnit.deallocateRenderResources()
            sink.close()
            state.endGeneration()
            try? FileManager.default.removeItem(at: url)
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            throw Self.startFailure(from: error)
        }

        // Scoped to this engine and stamped with this generation, so a notification arriving
        // after the recording ends cannot mark its successor as disrupted.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [state] _ in
            guard state.markDisrupted(generation: generation) else { return }
            log.warning("Input configuration changed mid-recording; capture has stopped")
        }

        self.engine = engine
        self.sink = sink
        currentURL = url
        currentSampleRate = format.sampleRate
        currentGeneration = generation
        log.info("Recording started at \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch")
        return url
    }

    func stopRecording() async throws -> URL {
        guard isRecording else { throw AudioRecorderError.notRecording }

        let generation = currentGeneration
        // Tear down in this order: no tap callbacks can be in flight once the tap is removed,
        // so reading and closing the sink afterwards can never race a write.
        teardownEngine()

        let (frames, writeError) = sink?.snapshot() ?? (0, nil)
        sink?.close()
        sink = nil

        // Read the disruption flag before retiring the generation, so this does not depend on
        // `endGeneration` happening to leave the flag behind.
        let disrupted = state.wasDisrupted(generation: generation)
        state.endGeneration()

        let sampleRate = currentSampleRate
        let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
        log.info("Recorded \(frames) frames (\(duration, format: .fixed(precision: 2))s)")

        let url = currentURL
        currentURL = nil
        currentSampleRate = 0
        currentGeneration = 0

        if let writeError {
            log.error("Recording write failed: \(writeError.localizedDescription, privacy: .public)")
            throw AudioRecorderError.writeFailed(writeError.localizedDescription)
        }
        // Audio captured before the switch is still the user's words, so it is transcribed
        // rather than discarded. Only when the switch left too little to work with does the
        // device change become the error, because "no audio was captured" would send the
        // user hunting for a broken microphone instead of explaining what happened.
        guard duration >= Self.minimumDuration else {
            if disrupted {
                log.error("Recording lost to an input device change after \(duration, format: .fixed(precision: 2))s")
                throw AudioRecorderError.inputDeviceChanged
            }
            log.error("Recording too short: \(duration, format: .fixed(precision: 2))s")
            throw AudioRecorderError.noAudioCaptured
        }
        if disrupted {
            log.warning("Input device changed mid-recording; transcribing the \(duration, format: .fixed(precision: 2))s captured before it")
        }
        guard let url else { throw AudioRecorderError.notRecording }
        return url
    }

    /// Releases the tap, the observer and the input hardware, then drops the engine. The
    /// engine is never reused: a new one is built for the next recording so its input node
    /// asks the hardware fresh. Without the explicit release the engine keeps the
    /// default-device aggregate (`CADefaultDeviceAggregate-<pid>-<n>`) alive, which shows up
    /// as a phantom input device.
    private func teardownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.inputNode.auAudioUnit.deallocateRenderResources()
        self.engine = nil
    }

    // MARK: - CoreAudio helpers

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
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
