#!/bin/zsh
# 녹음·전사와 전역 받아쓰기가 쓰는 파이썬 환경.
#
# 다른 세 환경(.venv-matting · .venv-media · .venv-docparse)과 일부러 갈라 둔다.
# 이쪽만 PyTorch와 pyannote를 통째로 끌고 오는데, 그 무게를 다른 도구까지 지게 하면
# 누끼 한 장을 따려고 2GB를 내려받게 된다.
set -eu

# 이 스크립트가 놓인 자리에서 구한다. 다른 사람이 어디에 내려받아도 그대로 돈다.
PROJECT_DIR="${0:A:h:h}"
# 가상환경은 저장소가 아니라 사용자 폴더에 만든다. `.dmg`로 앱만 받은 사람에게는
# 저장소가 없고, 서명된 번들 안에는 쓸 수 없기 때문이다.
VENV_ROOT="$HOME/Library/Application Support/SeoulLocalAgent/venvs"
/bin/mkdir -p "$VENV_ROOT"
VENV="$VENV_ROOT/.venv-transcription"

if ! command -v uv >/dev/null 2>&1; then
  print -u2 "uv가 필요합니다. 먼저 설치하세요:  brew install uv"
  exit 1
fi

uv venv --python 3.12 "$VENV"

# `mlx-qwen3-asr`가 Qwen3-ASR을 Apple Silicon의 MLX로 돌리는 부분이고, `pyannote.audio`가
# 화자를 가르는 부분이다. 화자 구분은 선택이지만 같은 환경에 함께 둔다 — 전사와 화자
# 구분은 같은 오디오를 두 번 읽으므로, 환경이 갈리면 같은 파일을 두 번 디코딩하게 된다.
VIRTUAL_ENV="$VENV" uv pip install --python "$VENV/bin/python" -U \
  "mlx-qwen3-asr>=0.3.5" \
  "pyannote.audio>=4.0"

print ""
print "전사 환경 준비됨: $VENV"
print ""
print "화자 구분(누가 말했는지 가르기)까지 쓰려면 pyannote 모델 접근 권한이 하나 더 필요합니다."
print "  1. https://huggingface.co/pyannote/speaker-diarization-community-1 에서 약관에 동의"
print "  2. https://huggingface.co/settings/tokens 에서 읽기 토큰을 만들기"
print "  3. 앱의 설정 › 전사에서 그 토큰을 넣기 (이 Mac의 키체인에만 저장됩니다)"
print ""
print "토큰이 없어도 전사 자체는 그대로 됩니다 — 화자 이름만 붙지 않습니다."
