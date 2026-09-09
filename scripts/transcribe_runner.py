#!/usr/bin/env python3
"""Offline Qwen3-ASR runner with observable stages and safe MPS fallback.

This helper deliberately owns the pyannote device choice instead of patching
site-packages.  It never sends audio or transcript data to a network service.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import sys
from pathlib import Path
from typing import Any

# Captured once per process so a retry can restore the untouched originals.
_ORIGINAL_INFER = None
_ORIGINAL_PIPELINE_LOADER = None


def write_status(path: Path, stage: str, detail: str, progress: float | None = None, backend: str | None = None) -> None:
    payload: dict[str, Any] = {"stage": stage, "detail": detail}
    if progress is not None:
        payload["progress"] = max(0.0, min(1.0, progress))
    if backend is not None:
        payload["backend"] = backend
    # The app polls this file while it is being rewritten, so swap it in atomically
    # instead of letting the reader observe a truncated document.
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, path)


def configure_diarization_backend(backend: str, status_path: Path):
    """Patch only the in-process pyannote loader; the installed package stays untouched."""
    global _ORIGINAL_INFER, _ORIGINAL_PIPELINE_LOADER
    diarization = importlib.import_module("mlx_qwen3_asr.diarization")
    transcribe_module = importlib.import_module("mlx_qwen3_asr.transcribe")

    if _ORIGINAL_INFER is None:
        _ORIGINAL_INFER = transcribe_module.infer_speaker_turns
    if _ORIGINAL_PIPELINE_LOADER is None:
        _ORIGINAL_PIPELINE_LOADER = diarization._load_pyannote_pipeline
    original_infer = _ORIGINAL_INFER

    def infer_with_stage(*args: Any, **kwargs: Any):
        write_status(status_path, "diarization", f"화자 분리 중 ({backend.upper()})", backend=backend)
        return original_infer(*args, **kwargs)

    transcribe_module.infer_speaker_turns = infer_with_stage
    if backend != "mps":
        # Without this the CPU retry kept the MPS loader installed by the failed
        # attempt, so the "safe mode" fallback ran on MPS again and failed again.
        diarization._load_pyannote_pipeline = _ORIGINAL_PIPELINE_LOADER
        return transcribe_module

    import torch

    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is not available")

    def load_on_mps():
        pipeline = _ORIGINAL_PIPELINE_LOADER()
        pipeline.to(torch.device("mps"))
        return pipeline

    diarization._load_pyannote_pipeline = load_on_mps
    return transcribe_module


def run_once(args: argparse.Namespace, backend: str) -> None:
    from mlx_qwen3_asr.writers import write_json

    status_path = Path(args.status_file)
    diarize = args.diarization != "disabled"
    if diarize:
        model_ids = {
            "community1": "pyannote/speaker-diarization-community-1",
            "legacy31": "pyannote/speaker-diarization-3.1",
        }
        os.environ["PYANNOTE_MODEL_ID"] = model_ids[args.diarization]
    transcribe_module = (
        configure_diarization_backend(backend, status_path)
        if diarize
        else importlib.import_module("mlx_qwen3_asr.transcribe")
    )

    def on_progress(event: dict[str, Any]) -> None:
        if event.get("event") == "chunk_completed":
            progress = float(event.get("progress", 0.0))
            stage_name = "GPU 음성 인식 중" if args.no_timestamps else "GPU 음성 인식·시간 정렬 중"
            write_status(status_path, "asr", f"{stage_name} ({int(progress * 100)}%)", progress, backend)

    cache = Path.home() / ".cache" / "seoul-local-agent"
    models = {
        "qwen06B8Bit": str(cache / "Qwen3-ASR-0.6B-8bit"),
        "qwen06B": "Qwen/Qwen3-ASR-0.6B",
        # 8-bit, not the original weights: same accuracy on FLEURS and 4.3x
        # faster, so the precise option is no longer the one nobody waits for.
        "qwen17B": str(cache / "Qwen3-ASR-1.7B-8bit"),
        "qwen17BSpeculative": "Qwen/Qwen3-ASR-1.7B",
    }
    model = models[args.asr_model]
    draft_model = "Qwen/Qwen3-ASR-0.6B" if args.asr_model == "qwen17BSpeculative" else None
    write_status(status_path, "loading", f"전사 모델 준비 중 ({backend.upper()})", backend=backend)
    result = transcribe_module.transcribe(
        args.audio,
        model=model,
        draft_model=draft_model,
        num_draft_tokens=6 if draft_model else 4,
        language=args.language,
        return_timestamps=not args.no_timestamps,
        diarize=diarize,
        diarization_min_speakers=1,
        diarization_max_speakers=8,
        on_progress=on_progress,
    )
    if not result.text.strip():
        raise RuntimeError("음성을 감지하지 못했습니다. 무음·매우 짧은 녹음이거나 iCloud 원본이 내려오지 않은 파일인지 확인해 주세요.")
    write_status(status_path, "writing", "전사 결과 저장 중", 1.0, backend)
    output_path = Path(args.output_dir) / f"{Path(args.audio).stem}.json"
    write_json(result, str(output_path))
    detail = "전사와 화자 구분 완료" if diarize else "전사 완료"
    write_status(status_path, "completed", detail, 1.0, backend)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--status-file", required=True)
    parser.add_argument("--asr-model", choices=("qwen06B8Bit", "qwen06B", "qwen17B", "qwen17BSpeculative"), required=True)
    parser.add_argument("--diarization", choices=("disabled", "community1", "legacy31"), required=True)
    parser.add_argument("--no-timestamps", action="store_true", help="Skip forced timestamp alignment")
    parser.add_argument("--language", choices=("Korean", "English"), default=None, help="Force a spoken language; omit for auto-detection")
    parser.add_argument("--backend", choices=("auto", "mps", "cpu"), default="auto")
    args = parser.parse_args()
    Path(args.output_dir).mkdir(parents=True, exist_ok=True)

    if args.diarization == "disabled":
        try:
            run_once(args, "mps")
            return 0
        except Exception as error:
            print(f"전사 실패: {error}", file=sys.stderr)
            return 1

    if args.backend in ("mps", "cpu"):
        run_once(args, args.backend)
        return 0

    # MPS is always attempted first. A failure safely reruns the job on CPU
    # rather than leaving the user with a failed recording.
    try:
        run_once(args, "mps")
        return 0
    except Exception as error:
        write_status(Path(args.status_file), "fallback", "MPS 화자 분리 호환성 문제: CPU 안전 모드로 다시 시작", backend="cpu")
        print(f"MPS diarization fallback: {type(error).__name__}: {error}", file=sys.stderr)
        try:
            run_once(args, "cpu")
            return 0
        except Exception as cpu_error:
            print(f"CPU diarization failed: {type(cpu_error).__name__}: {cpu_error}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
