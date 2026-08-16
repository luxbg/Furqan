import Foundation
import SherpaOnnx

/// Wraps sherpa-onnx's offline transducer recognizer, configured for our
/// exported NeMo FastConformer-RNNT model. `modelType: "nemo_transducer"` is
/// required (not the generic "transducer") - it dispatches to
/// `OfflineRecognizerTransducerNeMoImpl`, which matches this model's
/// (EncDecHybridRNNTCTCBPEModel) feature-extraction convention. The generic
/// type defaults to Kaldi-style features and would silently garble output.
nonisolated final class QuranTranscriber {
    private let recognizer: SherpaOnnxOfflineRecognizer

    init() {
        guard let encoderPath = Bundle.main.path(forResource: "encoder.int8", ofType: "onnx"),
              let decoderPath = Bundle.main.path(forResource: "decoder.int8", ofType: "onnx"),
              let joinerPath = Bundle.main.path(forResource: "joiner.int8", ofType: "onnx"),
              let tokensPath = Bundle.main.path(forResource: "tokens", ofType: "txt") else {
            fatalError("ASR model files missing from bundle")
        }

        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: encoderPath, decoder: decoderPath, joiner: joinerPath
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath, transducer: transducer, modelType: "nemo_transducer"
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// Blocking full re-decode of the given samples. Call off the main thread.
    func transcribe(samples: [Float]) -> String {
        recognizer.decode(samples: samples, sampleRate: 16_000).text
    }
}
