#!/bin/zsh
# Creates the Python environment for 소리 다듬기 (정밀) and 화질 올리기.
#
# Deliberately separate from .venv-matting and .venv-transcription: those are
# working combinations of torch, mlx and pyannote, and adding torchaudio and
# speechbrain to either risks breaking a feature that does not need to share
# anything. One environment covers both tools here because they are installed
# and resolved together and would otherwise hold two copies of torch.
set -eu

# 이 스크립트가 놓인 자리에서 구한다. 다른 사람이 어디에 내려받아도 그대로 돈다.
PROJECT_DIR="${0:A:h:h}"
VENV="$PROJECT_DIR/.venv-media"

cd "$PROJECT_DIR"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv를 찾지 못했습니다. 먼저 'brew install uv'를 실행해 주세요." >&2
  exit 1
fi

uv venv --python 3.12 "$VENV"
VIRTUAL_ENV="$VENV" uv pip install --python "$VENV/bin/python" \
  torch torchvision torchaudio numpy pillow spandrel speechbrain soundfile huggingface_hub

"$VENV/bin/python" - <<'PY'
import torch, soundfile, spandrel, speechbrain
print(f"torch {torch.__version__} / spandrel {spandrel.__version__} / speechbrain {speechbrain.__version__}")
print("MPS available:", torch.backends.mps.is_available())
PY

echo "완료: $VENV"
echo "가중치는 처음 쓸 때 ~/.cache/seoul-local-agent/hf 에 내려받습니다 (확대 약 65MB, 음성 분리 약 110MB)."
