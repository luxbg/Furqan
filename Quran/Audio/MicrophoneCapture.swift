import AVFoundation
import AudioToolbox
import CoreAudio

/// Taps the default input device, converts whatever native format the
/// device gives (typically 44.1/48kHz) to 16kHz mono Float32, and pushes
/// each converted chunk to a callback as it arrives - true streaming, for
/// the phoneme ASR's incremental `feedAudio` (unlike the old rolling-
/// buffer-plus-periodic-full-redecode design this replaced).
///
/// The callback runs on a dedicated serial delivery queue, never on
/// CoreAudio's own render thread - `StreamingPhonemeRecognizer.feedAudio`
/// runs a neural network and must never block the audio tap.
nonisolated final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let deliveryQueue = DispatchQueue(label: "MicrophoneCapture.delivery")
    private var onSamples: (([Float]) -> Void)?

    /// Mirrors the exact post-gain, post-resample audio handed to the ASR's
    /// `feedAudio` to a WAV file, so what the model actually hears can be
    /// played back and checked by ear. Overwritten each `start()`.
    private var debugRecording: AVAudioFile?
    static let debugRecordingURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/quran_asr_debug.wav")

    /// Must request/confirm mic authorization *before* touching
    /// `engine.inputNode` - reading its format (let alone installing a tap
    /// on it) while authorization is still `.notDetermined` gets back an
    /// invalid (0-channel) format on macOS, and `installTap` with an
    /// invalid format throws an uncaught Objective-C exception that
    /// crashes the process outright, with no dialog and nothing in the UI.
    func start(onSamples: @escaping ([Float]) -> Void) async throws {
        try await requestAuthorizationIfNeeded()
        self.onSamples = onSamples

        let input = engine.inputNode
        try Self.bindInputUnit(input, toDevice: Self.systemDefaultInputDeviceID())
        let inputFormat = input.inputFormat(forBus: 0)
        let nativeMonoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: nativeMonoFormat, to: targetFormat)
        debugRecording = try? AVAudioFile(forWriting: Self.debugRecordingURL, settings: targetFormat.settings)
//        print("TEMP-DEBUG default input device = \(Self.currentDefaultInputDeviceName()), tap format = \(inputFormat)")

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.consume(pcmBuffer, nativeMonoFormat: nativeMonoFormat)
        }
        engine.prepare()
        try engine.start()
    }

    /// Explicitly `@MainActor`: the system permission sheet only attaches
    /// and appears when this is requested from the main thread. Called
    /// from `start()`, which normally runs on a background `Task` - off
    /// the main thread, `requestAccess` can return `false` immediately
    /// with no dialog shown at all.
    @MainActor
    private func requestAuthorizationIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MicrophoneCaptureError.permissionDenied
            }
        case .denied, .restricted:
            throw MicrophoneCaptureError.permissionDenied
        @unknown default:
            throw MicrophoneCaptureError.permissionDenied
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        onSamples = nil
        debugRecording = nil
    }

    /// Downmixes to mono ourselves (averaging the first 1-2 channels, where
    /// real content lives for both a normal mic and a multichannel virtual
    /// device like BlackHole) before handing off to `converter`. Letting
    /// `AVAudioConverter` do the channel mixdown itself silently produces
    /// all-zero output for a source with a high/undefined channel count
    /// (confirmed live: BlackHole 16ch, real signal sitting on channels 0-1,
    /// converter output all zero) - it can't derive a mixdown matrix without
    /// a defined channel layout, so this bypasses that entirely and leaves
    /// the converter only a sample-rate change to do, which is unambiguous.
    private func consume(_ pcmBuffer: AVAudioPCMBuffer, nativeMonoFormat: AVAudioFormat) {
        guard let converter, let raw = pcmBuffer.floatChannelData else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        let downmixChannels = min(2, Int(pcmBuffer.format.channelCount))
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: nativeMonoFormat, frameCapacity: pcmBuffer.frameLength),
              let monoData = monoBuffer.floatChannelData else { return }
        monoBuffer.frameLength = pcmBuffer.frameLength
        for i in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<downmixChannels { sum += raw[ch][i] }
            monoData[0][i] = sum / Float(downmixChannels)
        }

        let outCapacity = AVAudioFrameCount(targetFormat.sampleRate * Double(frameCount) / nativeMonoFormat.sampleRate) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return monoBuffer
        }
        guard error == nil, let channelData = outBuffer.floatChannelData else { return }

        try? debugRecording?.write(from: outBuffer)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
        guard !samples.isEmpty else { return }
        let callback = onSamples
        deliveryQueue.async { callback?(samples) }
    }
}

enum MicrophoneCaptureError: Error {
    case permissionDenied
    case deviceBindFailed(OSStatus)
}

extension MicrophoneCapture {
    fileprivate static func systemDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID)
        return deviceID
    }

    /// Explicitly binds the input audio unit to a specific CoreAudio device,
    /// bypassing `AVAudioEngine`'s own default-device auto-resolution -- with
    /// BlackHole installed (even unselected), that auto-resolution has been
    /// observed reporting a bogus combined channel count (e.g. 18ch for a
    /// 2ch USB mic, 2+16 = the mic's channels plus BlackHole 16ch's), which
    /// silently produces all-zero sample buffers instead of real audio.
    fileprivate static func bindInputUnit(_ input: AVAudioInputNode, toDevice deviceID: AudioDeviceID) throws {
        guard let audioUnit = input.audioUnit else { return }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw MicrophoneCaptureError.deviceBindFailed(status) }
    }

    fileprivate static func currentDefaultInputDeviceName() -> String {
        let deviceID = systemDefaultInputDeviceID()
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        guard nameStatus == noErr else { return "device #\(deviceID) (name lookup failed)" }
        return "\(name as String) (#\(deviceID))"
    }
}
