#!/usr/bin/env python3
"""Offline background-removal (누끼) runner for the Seoul local agent.

Unlike `transcribe_runner.py`, which is spawned once per job, this runner stays
resident and answers newline-delimited JSON requests on stdin so the ~900MB
BiRefNet weights are loaded once instead of once per photo.

Staying resident is only acceptable if the process is guaranteed to die, so it
watches three independent conditions and exits on whichever fires first:

1. stdin EOF - the app's pipe closes even when the app is SIGKILLed.
2. The parent PID disappearing - covers a stdin that somehow stays open.
3. An idle timeout - hands the memory back when nobody is using the feature.

All three are checked from the single `select` loop in `serve`, so there is
exactly one exit path and no daemon threads that could outlive it.

No image ever leaves this machine; the only network access is the one-time
Hugging Face weight download.
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

MODELS: dict[str, tuple[str, int]] = {
    # key: (Hugging Face repo, the square resolution the checkpoint was trained at)
    "hr-matting": ("ZhengPeng7/BiRefNet_HR-matting", 2048),
    "matting": ("ZhengPeng7/BiRefNet-matting", 1024),
}

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


def emit(payload: dict[str, Any]) -> None:
    """Write one JSON line and flush; the app reads this stream line by line."""
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class Matter:
    """Owns the loaded model. Only one checkpoint is resident at a time."""

    def __init__(self) -> None:
        self._repo: str | None = None
        self._model = None
        # Set once fp16 has produced a broken mask; from then on stay in fp32
        # rather than paying for a failed pass on every subsequent photo.
        self._force_float32 = False

    def unload(self) -> None:
        if self._model is None:
            return
        self._model = None
        self._repo = None
        try:
            import torch

            torch.mps.empty_cache()
        except Exception:
            pass

    def _load(self, repo: str, progress) -> None:
        if self._repo == repo and self._model is not None:
            return
        import torch
        from transformers import AutoModelForImageSegmentation

        self.unload()
        progress("모델을 준비하고 있습니다. 첫 실행이면 약 900MB를 내려받습니다.")
        model = AutoModelForImageSegmentation.from_pretrained(repo, trust_remote_code=True)
        model.eval()
        dtype = torch.float32 if self._force_float32 else torch.float16
        model.to(device="mps", dtype=dtype)
        self._model = model
        self._repo = repo

    def _infer(self, tensor, dtype):
        import torch

        with torch.no_grad():
            output = self._model(tensor.to(device="mps", dtype=dtype))
        # BiRefNet returns a list of supervision maps; the last one is the result.
        logits = output[-1] if isinstance(output, (list, tuple)) else output
        return logits.sigmoid().float().cpu()

    def cutout(self, source: Path, destination: Path, model_key: str, progress) -> dict[str, Any]:
        import numpy as np
        import torch
        from PIL import Image, ImageOps

        repo, size = MODELS[model_key]
        image = ImageOps.exif_transpose(Image.open(source)).convert("RGB")
        self._load(repo, progress)

        progress("배경을 분리하고 있습니다.")
        array = np.asarray(image.resize((size, size), Image.BILINEAR), dtype=np.float32) / 255.0
        array = (array - np.asarray(IMAGENET_MEAN, dtype=np.float32)) / np.asarray(IMAGENET_STD, dtype=np.float32)
        tensor = torch.from_numpy(array).permute(2, 0, 1).unsqueeze(0)

        dtype = torch.float32 if self._force_float32 else torch.float16
        alpha = self._infer(tensor, dtype)
        if not self._usable(alpha) and dtype is torch.float16:
            # Known fp16-on-MPS failure: the mask comes back all-NaN or all-zero.
            # Fall back for this photo and stay in fp32 afterwards.
            progress("정밀도를 낮춰 다시 계산하고 있습니다.")
            self._force_float32 = True
            self._model.to(dtype=torch.float32)
            alpha = self._infer(tensor, torch.float32)
        if not self._usable(alpha):
            raise RuntimeError("배경을 분리하지 못했습니다. 다른 사진으로 다시 시도해 주세요.")

        mask = Image.fromarray((alpha.squeeze().clamp(0, 1).numpy() * 255).astype(np.uint8), mode="L")
        image.putalpha(mask.resize(image.size, Image.BICUBIC))
        destination.parent.mkdir(parents=True, exist_ok=True)
        image.save(destination, format="PNG")
        torch.mps.empty_cache()
        return {"output": str(destination), "width": image.width, "height": image.height}

    @staticmethod
    def _usable(alpha) -> bool:
        import torch

        return bool(torch.isfinite(alpha).all() and alpha.max() > 0.02)


def handle(matter: Matter, request: dict[str, Any]) -> None:
    request_id = request.get("id")

    def progress(detail: str) -> None:
        emit({"id": request_id, "event": "progress", "detail": detail})

    try:
        model_key = request.get("model", "hr-matting")
        if model_key not in MODELS:
            raise ValueError(f"알 수 없는 모델입니다: {model_key}")
        source = Path(request["input"])
        if not source.is_file():
            raise FileNotFoundError(f"사진을 찾지 못했습니다: {source.name}")
        started = time.monotonic()
        result = matter.cutout(source, Path(request["output"]), model_key, progress)
        emit({"id": request_id, "ok": True, "ms": int((time.monotonic() - started) * 1000), **result})
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
    matter = Matter()
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
                    handle(matter, request)
            last_activity = time.monotonic()
        elif idle_timeout > 0 and time.monotonic() - last_activity > idle_timeout:
            break
    matter.unload()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Resident background-removal runner.")
    parser.add_argument("--parent-pid", type=int, default=0, help="Exit once this process is gone.")
    parser.add_argument("--idle-timeout", type=float, default=300.0, help="Seconds of inactivity before unloading and exiting.")
    args = parser.parse_args()
    # Hugging Face progress bars would interleave with the JSON protocol.
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TQDM_DISABLE", "1")
    return serve(args.parent_pid, args.idle_timeout)


if __name__ == "__main__":
    sys.exit(main())
