import AVFoundation
import CoreAudio

/// Always-warm capture: the engine runs continuously (negligible CPU), feeding a
/// rolling pre-buffer so dictation includes ~0.5s BEFORE the hotkey press —
/// this kills first-word clipping and Bluetooth-mic wake loss (spec §2).
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    public let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring: RingBuffer
    private var active: [Float] = []
    private var accumulating = false
    private var resampler: AudioResampler?
    private let preBufferSamples: Int

    public init(preBufferSeconds: TimeInterval = 0.5) {
        preBufferSamples = Int(preBufferSeconds * AudioData.sampleRate)
        ring = RingBuffer(capacity: preBufferSamples)
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.rebuildTap()   // AirPods connect/disconnect, default-device change
        }
    }

    // MARK: permissions / devices

    public static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    public static func availableInputs() -> [(uid: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// nil = system default. Sets the engine input device via CoreAudio.
    public func setPreferredInput(uid: String?) {
        guard let uid else { return rebuildTap() }   // revert to default on nil
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr,
                                       &size, &deviceID)
        }
        guard status == noErr, deviceID != 0, let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        rebuildTap()
    }

    // MARK: engine lifecycle

    public func warmUp() throws {
        installTap()
        engine.prepare()
        try engine.start()
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let newResampler = AudioResampler(inputFormat: format)
        // `resampler` is read on the audio render thread (ingest); every access
        // must be lock-guarded. Lock only the assignment — never AVAudioEngine calls.
        lock.lock()
        resampler = newResampler
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
    }

    private func rebuildTap() {
        installTap()   // takes the lock itself for the resampler swap
        if !engine.isRunning { engine.prepare(); try? engine.start() }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let resampler = self.resampler
        lock.unlock()
        // process() stays OUTSIDE the lock: it is expensive and the audio thread
        // must not hold the lock during conversion. The converter itself is only
        // ever touched from this render thread — the race was the property.
        guard let samples = resampler?.process(buffer), !samples.isEmpty else { return }
        var rms: Float = 0
        for s in samples { rms += s * s }
        rms = min(1, sqrt(rms / Float(samples.count)) * 4)   // scaled for HUD meters
        lock.lock()
        ring.write(samples)
        if accumulating { active.append(contentsOf: samples) }
        lock.unlock()
        levelContinuation.yield(rms)
    }

    // MARK: AudioCapturing

    public func startCapture() throws {
        if !engine.isRunning { try warmUp() }
        lock.lock(); defer { lock.unlock() }
        active = ring.snapshot()   // splice in the pre-roll
        accumulating = true
    }

    public func stopCapture() async -> AudioData {
        // NSLock.lock()/unlock() are marked unavailable inside async bodies
        // (noasync); withLock is the sanctioned scoped equivalent. No await
        // occurs under the lock, so this is safe.
        lock.withLock {
            accumulating = false
            let samples = active
            active = []
            return AudioData(samples: samples)
        }
    }

    public func cancelCapture() {
        lock.lock(); defer { lock.unlock() }
        accumulating = false
        active = []
    }
}
