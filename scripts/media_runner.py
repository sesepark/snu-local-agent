#!/usr/bin/env python3
"""Resident runner for 소리 다듬기 (정밀) and 화질 올리기.

Built to the same contract as `matting_runner.py`: newline-delimited JSON
requests on stdin, newline-delimited JSON events on stdout, and a process that
is guaranteed to die. It watches three independent conditions and exits on
whichever fires first:

1. stdin EOF - the app's pipe closes even when the app is SIGKILLed.
2. The parent PID disappearing - covers a stdin that somehow stays open.
3. An idle timeout - hands the memory back when nobody is using the feature.

All three are checked from the single `select` loop in `serve`, so there is
exactly one exit path and no daemon threads that could outlive it.

One process serves both tasks because they are never used at the same time -
they are different screens - and two resident torch processes would hold a
gigabyte each. Whichever model is not being asked for is unloaded.

Nothing leaves this machine; the only network access is the one-time weight
download from Hugging Face.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import sys
import time
from pathlib import Path
from typing import Any

UPSCALE_MODELS: dict[str, tuple[str, str]] = {
    # key: (Hugging Face repo, file)
    "realesrgan-x2": ("ai-forever/Real-ESRGAN", "RealESRGAN_x2.pth"),
    "realesrgan-x4": ("ai-forever/Real-ESRGAN", "RealESRGAN_x4.pth"),
}

ENHANCE_REPO = "speechbrain/sepformer-dns4-16k-enhancement"
SAMPLE_RATE = 16000
# Tiles keep peak memory flat: a 48MP photo at four times over would otherwise
# need a single tensor of several gigabytes on the GPU.
TILE = 512
TILE_OVERLAP = 32


def emit(payload: dict[str, Any]) -> None:
    """Write one JSON line and flush; the app reads this stream line by line."""
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def device() -> str:
    import torch

    return "mps" if torch.backends.mps.is_available() else "cpu"


class Models:
    """Owns whatever is loaded. Only one of the two is resident at a time."""

    def __init__(self) -> None:
        self._upscaler = None
        self._upscaler_key: str | None = None
        self._enhancer = None

    def unload_upscaler(self) -> None:
        self._upscaler = None
        self._upscaler_key = None
        self._empty_cache()

    def unload_enhancer(self) -> None:
        self._enhancer = None
        self._empty_cache()

    def unload_all(self) -> None:
        self.unload_upscaler()
        self.unload_enhancer()

    @staticmethod
    def _empty_cache() -> None:
        try:
            import torch

            torch.mps.empty_cache()
        except Exception:
            pass

    # ---------------- 화질 올리기 ----------------

    def upscaler(self, key: str, progress):
        if self._upscaler_key == key and self._upscaler is not None:
            return self._upscaler
        import torch
        from huggingface_hub import hf_hub_download
        from spandrel import ModelLoader

        self.unload_all()
        repo, filename = UPSCALE_MODELS[key]
        progress("모델을 준비하고 있습니다. 첫 실행이면 내려받습니다.", None)
        path = hf_hub_download(repo, filename)
        model = ModelLoader().load_from_file(path)
        model.to(device()).eval()
        # fp32 throughout: the fp16 path on MPS produces black tiles for some of
        # these checkpoints, and the model is small enough that it costs little.
        self._upscaler = model
        self._upscaler_key = key
        return model

    def upscale(self, request: dict[str, Any], progress) -> dict[str, Any]:
        import numpy as np
        import torch
        from PIL import Image, ImageOps

        key = request.get("model", "realesrgan-x2")
        if key not in UPSCALE_MODELS:
            raise ValueError(f"알 수 없는 모델입니다: {key}")
        source = Path(request["input"])
        if not source.is_file():
            raise FileNotFoundError(f"사진을 찾지 못했습니다: {source.name}")

        model = self.upscaler(key, progress)
        scale = int(model.scale)
        image = ImageOps.exif_transpose(Image.open(source)).convert("RGB")
        width, height = image.size

        array = np.asarray(image, dtype=np.float32) / 255.0
        tensor = torch.from_numpy(array).permute(2, 0, 1).unsqueeze(0)
        result = torch.zeros(1, 3, height * scale, width * scale, dtype=torch.float32)
        weight = torch.zeros(1, 1, height * scale, width * scale, dtype=torch.float32)

        rows = list(range(0, height, TILE - TILE_OVERLAP))
        columns = list(range(0, width, TILE - TILE_OVERLAP))
        total = len(rows) * len(columns)
        done = 0
        progress("사진을 확대하고 있습니다.", 0.0)

        for top in rows:
            for left in columns:
                bottom = min(top + TILE, height)
                right = min(left + TILE, width)
                tile = tensor[:, :, top:bottom, left:right].to(device())
                with torch.no_grad():
                    enlarged = model(tile).clamp(0, 1).float().cpu()
                result[:, :, top * scale:bottom * scale, left * scale:right * scale] += enlarged
                weight[:, :, top * scale:bottom * scale, left * scale:right * scale] += 1
                done += 1
                progress("사진을 확대하고 있습니다.", done / total)

        # Overlapping tiles are averaged rather than overwritten, so the seams do
        # not show as faint lines across the picture.
        result = result / weight.clamp(min=1)
        pixels = (result.squeeze(0).permute(1, 2, 0).numpy() * 255).round().clip(0, 255).astype(np.uint8)
        enlarged_image = Image.fromarray(pixels)

        cap = int(request.get("maxLongEdge", 6000))
        if cap > 0 and max(enlarged_image.size) > cap:
            factor = cap / max(enlarged_image.size)
            target = (max(1, round(enlarged_image.width * factor)), max(1, round(enlarged_image.height * factor)))
            enlarged_image = enlarged_image.resize(target, Image.LANCZOS)

        destination = Path(request["output"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Always PNG: the app converts to whichever format the user asked for,
        # which keeps every image encoder this project depends on inside macOS.
        enlarged_image.save(destination, format="PNG")
        self._empty_cache()
        return {"width": enlarged_image.width, "height": enlarged_image.height, "scale": scale}

    # ---------------- 소리 다듬기 ----------------

    def enhancer(self, progress):
        if self._enhancer is not None:
            return self._enhancer
        from speechbrain.inference.separation import SepformerSeparation

        self.unload_all()
        progress("음성 분리 모델을 준비하고 있습니다. 첫 실행이면 내려받습니다.", None)
        cache = Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface")) / "speechbrain-sepformer"
        model = SepformerSeparation.from_hparams(
            source=ENHANCE_REPO, savedir=str(cache), run_opts={"device": device()}
        )
        self._enhancer = model
        return model

    def enhance(self, request: dict[str, Any], progress) -> dict[str, Any]:
        import numpy as np
        import soundfile as sf
        import torch

        source = Path(request["input"])
        if not source.is_file():
            raise FileNotFoundError(f"소리 파일을 찾지 못했습니다: {source.name}")
        model = self.enhancer(progress)

        audio, rate = sf.read(source, dtype="float32", always_2d=True)
        signal = audio.mean(axis=1)
        if rate != SAMPLE_RATE:
            raise ValueError(f"16 kHz 모노만 처리합니다 (받은 값: {rate} Hz).")

        # Chunked with a crossfade rather than fed in whole: a one-hour lecture
        # is 57 million samples and the transformer's attention would not fit.
        chunk = int(float(request.get("chunkSeconds", 10)) * SAMPLE_RATE)
        overlap = SAMPLE_RATE // 2
        step = max(1, chunk - overlap)
        output = np.zeros(len(signal), dtype=np.float32)
        weight = np.zeros(len(signal), dtype=np.float32)
        starts = list(range(0, max(1, len(signal)), step))
        progress("잡음을 걷어내고 있습니다.", 0.0)

        for index, start in enumerate(starts):
            end = min(start + chunk, len(signal))
            piece = signal[start:end]
            if len(piece) < 512:
                break
            with torch.no_grad():
                estimate = model.separate_batch(torch.from_numpy(piece).unsqueeze(0).to(device()))
            cleaned = estimate[:, :, 0].squeeze(0).float().cpu().numpy()[: len(piece)]
            # A linear fade over the overlap, so a chunk boundary is not audible
            # as a click.
            envelope = np.ones(len(cleaned), dtype=np.float32)
            fade = min(overlap, len(cleaned) // 2)
            if fade > 0:
                if start > 0:
                    envelope[:fade] = np.linspace(0, 1, fade, dtype=np.float32)
                if end < len(signal):
                    envelope[-fade:] = np.linspace(1, 0, fade, dtype=np.float32)
            output[start:end] += cleaned * envelope
            weight[start:end] += envelope
            progress("잡음을 걷어내고 있습니다.", (index + 1) / len(starts))

        output = output / np.maximum(weight, 1e-6)
        destination = Path(request["output"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        sf.write(destination, output, SAMPLE_RATE, subtype="FLOAT")
        self._empty_cache()
        return {"seconds": round(len(signal) / SAMPLE_RATE, 2)}


def handle(models: Models, request: dict[str, Any]) -> None:
    request_id = request.get("id")

    def progress(detail: str, fraction: float | None) -> None:
        payload: dict[str, Any] = {"id": request_id, "event": "progress", "detail": detail}
        if fraction is not None:
            payload["fraction"] = max(0.0, min(1.0, float(fraction)))
        emit(payload)

    try:
        task = request.get("task")
        started = time.monotonic()
        if task == "upscale":
            result = models.upscale(request, progress)
        elif task == "enhance":
            result = models.enhance(request, progress)
        else:
            raise ValueError(f"알 수 없는 작업입니다: {task}")
        emit({
            "id": request_id, "ok": True, "output": request["output"],
            "ms": int((time.monotonic() - started) * 1000), **result,
        })
    except Exception as error:  # reported to the app, never crashes the daemon
        emit({"id": request_id, "ok": False, "error": str(error) or type(error).__name__})


def parent_alive(parent_pid: int) -> bool:
    if parent_pid <= 1:
        return True
    try:
        os.kill(parent_pid, 0)
    except OSError:
        return False
    return True


def serve(parent_pid: int, idle_timeout: float) -> int:
    models = Models()
    last_activity = time.monotonic()
    emit({"event": "ready", "pid": os.getpid()})
    while True:
        ready, _, _ = select.select([sys.stdin], [], [], 5.0)
        if not parent_alive(parent_pid):
            break
        if ready:
            line = sys.stdin.readline()
            if line == "":  # the app closed the pipe, or died
                break
            line = line.strip()
            if line:
                try:
                    request = json.loads(line)
                except json.JSONDecodeError:
                    emit({"ok": False, "error": "잘못된 요청 형식입니다."})
                else:
                    handle(models, request)
            last_activity = time.monotonic()
        elif idle_timeout > 0 and time.monotonic() - last_activity > idle_timeout:
            break
    models.unload_all()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Resident audio-enhancement and upscaling runner.")
    parser.add_argument("--parent-pid", type=int, default=0, help="Exit once this process is gone.")
    parser.add_argument("--idle-timeout", type=float, default=300.0, help="Seconds of inactivity before unloading and exiting.")
    args = parser.parse_args()
    # Progress bars would interleave with the JSON protocol.
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TQDM_DISABLE", "1")
    return serve(args.parent_pid, args.idle_timeout)


if __name__ == "__main__":
    sys.exit(main())
