import Foundation
import SherpaOnnx

/// One decoded phoneme symbol emitted by the streaming recognizer, with its
/// emission timestamp. Port of `qrc/asr/streaming_recognizer.py`'s
/// `PhonemeToken`.
struct PhonemeToken {
    let symbol: String
    let timeS: Float
}

/// Wraps sherpa-onnx's streaming zipformer2-CTC recognizer, configured for
/// the Quran-Lab phoneme model. Replaces `QuranTranscriber` (which wrapped
/// an *offline* NeMo RNN-T recognizer requiring a full-buffer re-decode on
/// every tick) - this is a true incremental streamer: feed small chunks as
/// they arrive, poll newly emitted tokens.
///
/// Deliberately: no hotwords, no context biasing, no LM, endpoint detection
/// disabled (continuous multi-ayah session, never auto-segmented) - biasing
/// decoding toward the expected/canonical phonemes once an ayah is
/// localized would suppress exactly the deviations this tool exists to
/// detect. Mirrors `StreamingPhonemeRecognizer`'s "no LM anywhere" design
/// note in `qrc`.
nonisolated final class StreamingPhonemeRecognizer {
    private let recognizer: SherpaOnnxRecognizer
    private var emitted = 0

    init(sampleRate: Int = 16_000, numThreads: Int32 = 2) {
        guard let modelPath = Bundle.main.path(forResource: "phoneme_model.int8", ofType: "onnx"),
              let tokensPath = Bundle.main.path(forResource: "phoneme_tokens", ofType: "txt") else {
            fatalError("phoneme ASR model files missing from bundle")
        }

        let zipformer2Ctc = sherpaOnnxOnlineZipformer2CtcModelConfig(model: modelPath)
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokensPath,
            zipformer2Ctc: zipformer2Ctc,
            numThreads: Int(numThreads),
            provider: "cpu"
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: Int(sampleRate), featureDim: 80)
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: false,
            decodingMethod: "greedy_search"
        )
        recognizer = SherpaOnnxRecognizer(config: &config)
    }

    /// Feed a chunk of 16kHz mono Float32 samples and drain the decoder.
    /// Call off the main thread - this is where the neural network runs.
    func feedAudio(samples: [Float], sampleRate: Int = 16_000) {
        guard !samples.isEmpty else { return }
        recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)
        while recognizer.isReady() {
            recognizer.decode()
        }
    }

    /// New tokens emitted since the last call to `pollNewTokens`/`finish`.
    func pollNewTokens() -> [PhonemeToken] {
        let result = recognizer.getResult()
        let tokens = result.tokens
        let timestamps = result.timestamps
        guard emitted < tokens.count else { return [] }
        let newTokens = zip(tokens[emitted...], timestamps[min(emitted, timestamps.count)...])
            .map { PhonemeToken(symbol: $0.0, timeS: $0.1) }
        emitted = tokens.count
        return newTokens
    }

    /// Flush any remaining buffered audio and return whatever tokens that
    /// produces. Call once at end of session.
    func finish() -> [PhonemeToken] {
        recognizer.inputFinished()
        while recognizer.isReady() {
            recognizer.decode()
        }
        return pollNewTokens()
    }
}
