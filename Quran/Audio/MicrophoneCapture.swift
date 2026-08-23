import AVFoundation

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
        let inputFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.consume(pcmBuffer, inputFormat: inputFormat)
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
    }

    private func consume(_ pcmBuffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter else { return }
        let outCapacity = AVAudioFrameCount(targetFormat.sampleRate * Double(pcmBuffer.frameLength) / inputFormat.sampleRate) + 16
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
            return pcmBuffer
        }
        guard error == nil, let channelData = outBuffer.floatChannelData else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
        guard !samples.isEmpty else { return }
        let callback = onSamples
        deliveryQueue.async { callback?(samples) }
    }
}

enum MicrophoneCaptureError: Error {
    case permissionDenied
}
