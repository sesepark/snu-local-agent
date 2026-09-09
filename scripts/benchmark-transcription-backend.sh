#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 || ! -f "$1" ]]; then
  print -u2 "Usage: $0 /path/to/recording [asr-model] [diarization]"
  print -u2 "  asr-model:    qwen06B8Bit | qwen06B | qwen17B | qwen17BSpeculative (default: qwen06B8Bit)"
  print -u2 "  diarization:  community1 | legacy31 (default: community1)"
  exit 64
fi

ASR_MODEL=${2:-qwen06B8Bit}
DIARIZATION=${3:-community1}

ROOT_DIR=${0:A:h:h}
PYTHON="$ROOT_DIR/.venv-transcription/bin/python"
RUNNER="$ROOT_DIR/scripts/transcribe_runner.py"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/seoul-local-agent-benchmark.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

ffmpeg -hide_banner -loglevel error -y -i "$1" -t 300 "$WORK_DIR/sample.m4a"

run_backend() {
  local backend="$1"
  local started=$SECONDS
  "$PYTHON" "$RUNNER" "$WORK_DIR/sample.m4a" \
    --output-dir "$WORK_DIR/$backend" \
    --status-file "$WORK_DIR/$backend-status.json" \
    --asr-model "$ASR_MODEL" \
    --diarization "$DIARIZATION" \
    --backend "$backend"
  print "$backend elapsed_seconds=$((SECONDS - started))"
}

run_backend mps
run_backend cpu
