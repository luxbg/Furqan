import AVFoundation

/// Taps the default input device, converts whatever native format the
/// device gives (typically 44.1/48kHz) to 16kHz mono Float32, and keeps a
/// rolling 30-second window of samples for periodic full re-decode (see
/// RecitationSession) rather than growing the buffer for the whole session.
nonisolated final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let maxSamples = 16_000 * 30

    private let queue = DispatchQueue(label: "MicrophoneCapture.buffer")
    private var buffer: [Float] = []

    /// Must request/confirm mic authorization *before* touching
    /// `engine.inputNode` - reading its format (let alone installing a tap
    /// on it) while authorization is still `.notDetermined` gets back an
    /// invalid (0-channel) format on macOS, and `installTap` with an
    /// invalid format throws an uncaught Objective-C exception that
    /// crashes the process outright, with no dialog and nothing in the UI.
    func start() async throws {
        try await requestAuthorizationIfNeeded()

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
        queue.sync { buffer.removeAll() }
    }

    /// Snapshot of the current rolling window, oldest sample first.
    func snapshot() -> [Float] {
        queue.sync { buffer }
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
        queue.sync {
            buffer.append(contentsOf: samples)
            if buffer.count > maxSamples {
                buffer.removeFirst(buffer.count - maxSamples)
            }
        }
    }
}

enum MicrophoneCaptureError: Error {
    case permissionDenied
}
