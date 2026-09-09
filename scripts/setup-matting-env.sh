#!/bin/zsh
# Creates the Python environment for the 누끼(background removal) tab.
#
# Deliberately separate from .venv-transcription: that environment is a working
# combination of torch, mlx and pyannote, and adding torchvision to it risks
# breaking transcription for a feature that does not need to share anything.
set -eu

# 이 스크립트가 놓인 자리에서 구한다. 다른 사람이 어디에 내려받아도 그대로 돈다.
PROJECT_DIR="${0:A:h:h}"
VENV="$PROJECT_DIR/.venv-matting"

cd "$PROJECT_DIR"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv를 찾지 못했습니다. 먼저 'brew install uv'를 실행해 주세요." >&2
  exit 1
fi

uv venv --python 3.12 "$VENV"
VIRTUAL_ENV="$VENV" uv pip install --python "$VENV/bin/python" \
  torch torchvision transformers timm pillow numpy einops kornia

"$VENV/bin/python" - <<'PY'
import torch, torchvision, transformers
print(f"torch {torch.__version__} / torchvision {torchvision.__version__} / transformers {transformers.__version__}")
print("MPS available:", torch.backends.mps.is_available())
PY

echo "완료: $VENV"
echo "모델 가중치는 처음 누끼를 딸 때 ~/.cache/seoul-local-agent/hf 에 내려받습니다."
