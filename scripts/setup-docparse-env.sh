#!/bin/zsh
# Creates the Python environment for 문서 인식의 `정밀 (수식·표)` mode.
#
# Its own venv, like .venv-matting: MinerU pulls a large dependency tree of its
# own and the transcription environment is a working combination that should not
# be disturbed for a feature that shares nothing with it.
set -eu

# 이 스크립트가 놓인 자리에서 구한다. 다른 사람이 어디에 내려받아도 그대로 돈다.
PROJECT_DIR="${0:A:h:h}"
VENV="$PROJECT_DIR/.venv-docparse"
export HF_HOME="$HOME/.cache/seoul-local-agent/hf"
# The Xet transfer backend stalled partway through the model download on this
# machine; the plain HTTP path is slower to start but finishes.
export HF_HUB_DISABLE_XET=1
export MINERU_MODEL_SOURCE=huggingface

cd "$PROJECT_DIR"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv를 찾지 못했습니다. 먼저 'brew install uv'를 실행해 주세요." >&2
  exit 1
fi

uv venv --python 3.12 "$VENV"
uv pip install --python "$VENV/bin/python" -U "mineru[all]"

# Fetch the weights now rather than on the first document, so the first use in
# the app is fast and a download failure surfaces here instead of in the UI.
"$VENV/bin/hf" download opendatalab/MinerU2.5-Pro-2605-1.2B

echo "완료: $VENV"
echo "모델은 $HF_HOME 에 있습니다."
