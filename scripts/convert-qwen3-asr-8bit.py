#!/usr/bin/env python3
"""Create a local MLX 8-bit Qwen3-ASR model without replacing the source.

8-bit is where this family stops being free: measured on FLEURS, 8-bit matches
the original weights (Korean CER 3.79 vs 3.87 for 1.7B, 4.87 vs 4.91 for 0.6B)
while 4-bit falls behind the 0.6B model it is meant to beat (CER 5.17). So the
bit width here is a measured floor, not a knob to tune.
"""

import argparse
import json
import shutil
from pathlib import Path

import mlx.core as mx
import mlx.utils as mlx_utils
from mlx_qwen3_asr.config import Qwen3ASRConfig
from mlx_qwen3_asr.convert import quantize_model, remap_weights
from mlx_qwen3_asr.load_models import _load_safetensors, _resolve_path
from mlx_qwen3_asr.model import Qwen3ASRModel

CACHE = Path.home() / ".cache" / "seoul-local-agent"
MODELS = {
    "0.6B": ("Qwen/Qwen3-ASR-0.6B", CACHE / "Qwen3-ASR-0.6B-8bit"),
    "1.7B": ("Qwen/Qwen3-ASR-1.7B", CACHE / "Qwen3-ASR-1.7B-8bit"),
}
# Copied verbatim so the quantized folder loads standalone, without reaching
# back into the Hugging Face cache the source came from.
SIDECAR_FILES = (
    "config.json", "tokenizer.json", "tokenizer_config.json",
    "vocab.json", "merges.txt", "special_tokens_map.json", "preprocessor_config.json",
)


def convert(size: str) -> Path:
    source_id, destination = MODELS[size]
    source = _resolve_path(source_id)
    config = Qwen3ASRConfig.from_dict(json.loads((source / "config.json").read_text()))
    weights = {key: value.astype(mx.float16) for key, value in remap_weights(_load_safetensors(source)).items()}

    model = Qwen3ASRModel(config)
    model.load_weights(list(weights.items()))
    quantize_model(model, bits=8, group_size=64)
    mx.eval(model.parameters())

    destination.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(destination / "weights.safetensors"), dict(mlx_utils.tree_flatten(model.parameters())))
    for filename in SIDECAR_FILES:
        candidate = source / filename
        if candidate.exists():
            shutil.copy2(candidate, destination / filename)
    (destination / "quantization_config.json").write_text(json.dumps({"bits": 8, "group_size": 64}, indent=2))
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("size", choices=sorted(MODELS), help="Which Qwen3-ASR model to quantize")
    args = parser.parse_args()
    print(convert(args.size))


if __name__ == "__main__":
    main()
