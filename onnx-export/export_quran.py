#!/usr/bin/env python3
"""Export mohammed/fastconformer-quran-ar (phase3_full checkpoint) to sherpa-onnx
transducer format, reusing the already-cached .nemo checkpoint instead of
re-downloading the whole HF repo via NeMo's from_pretrained().
"""
from typing import Dict

import nemo.collections.asr as nemo_asr
import onnx
import torch
from huggingface_hub import hf_hub_download
from onnxruntime.quantization import QuantType, quantize_dynamic

REPO_ID = "mohammed/fastconformer-quran-ar"
CHECKPOINT = "phase3_full/phase3_full_wer0.0014.nemo"


def add_meta_data(filename: str, meta_data: Dict[str, str]):
    model = onnx.load(filename)
    while len(model.metadata_props):
        model.metadata_props.pop()
    for key, value in meta_data.items():
        meta = model.metadata_props.add()
        meta.key = key
        meta.value = str(value)
    onnx.save(model, filename)


@torch.no_grad()
def main():
    path = hf_hub_download(REPO_ID, CHECKPOINT)
    asr_model = nemo_asr.models.EncDecHybridRNNTCTCBPEModel.restore_from(path)

    with open("./tokens.txt", "w", encoding="utf-8") as f:
        for i, s in enumerate(asr_model.joint.vocabulary):
            f.write(f"{s} {i}\n")
        f.write(f"<blk> {i+1}\n")
    print("Saved to tokens.txt")

    asr_model.change_decoding_strategy(decoder_type="rnnt")
    asr_model.eval()
    asr_model.set_export_config({"decoder_type": "rnnt"})

    asr_model.encoder.export("encoder.onnx")
    asr_model.decoder.export("decoder.onnx")
    asr_model.joint.export("joiner.onnx")

    normalize_type = asr_model.cfg.preprocessor.normalize
    if normalize_type == "NA":
        normalize_type = ""
    meta_data = {
        "vocab_size": asr_model.decoder.vocab_size,
        "normalize_type": normalize_type,
        "pred_rnn_layers": asr_model.decoder.pred_rnn_layers,
        "pred_hidden": asr_model.decoder.pred_hidden,
        "subsampling_factor": 8,
        "model_type": "EncDecHybridRNNTCTCBPEModel",
        "version": "1",
        "model_author": "NeMo",
        "url": f"https://huggingface.co/{REPO_ID}",
        "comment": "Only the transducer branch is exported",
        "doc": "quran live transcription",
    }
    add_meta_data("encoder.onnx", meta_data)

    for m in ["encoder", "decoder", "joiner"]:
        quantize_dynamic(
            model_input=f"{m}.onnx",
            model_output=f"{m}.int8.onnx",
            weight_type=QuantType.QUInt8,
        )

    print(meta_data)


if __name__ == "__main__":
    main()
