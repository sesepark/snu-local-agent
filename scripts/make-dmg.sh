#!/bin/zsh
# 받는 사람이 끌어다 놓기만 하면 되는 디스크 이미지를 만든다.
#
# 앱을 zip으로 주지 않는 이유는 두 가지다. 하나는 압축을 풀면 다운로드 폴더에
# 그냥 떨어져서 사람마다 앱이 어디 있는지 달라진다는 것, 다른 하나는 `.dmg`가
# `Applications` 별칭을 함께 담을 수 있어 "여기로 끌어다 놓으세요"가 그림으로
# 설명된다는 것이다.
set -eu

PROJECT_DIR="${0:A:h:h}"
APP="$PROJECT_DIR/dist/SeoulLocalAgent.app"
STAGE="$PROJECT_DIR/dist/dmg-stage"
DMG="$PROJECT_DIR/dist/SeoulLocalAgent.dmg"

[ -d "$APP" ] || { print -u2 "먼저 ./scripts/build-app-bundle.sh 를 실행하세요."; exit 1; }

/bin/rm -rf "$STAGE" "$DMG"
/bin/mkdir -p "$STAGE"
/bin/cp -R "$APP" "$STAGE/"
/bin/ln -s /Applications "$STAGE/Applications"

# 창을 열었을 때 읽히도록 안내를 한 장 넣는다. Gatekeeper 때문에 첫 실행이
# 평범하지 않은데, 그것을 모른 채 "손상되었다"는 말을 보면 대부분 지우고 만다.
/bin/cat > "$STAGE/먼저 읽어 주세요.txt" <<'TXT'
서울대 로컬 에이전트 — 설치

1. 왼쪽의 앱을 오른쪽 Applications 폴더로 끌어다 놓으세요.

2. 처음 열 때는 두 번 누르지 말고, 앱을 **우클릭 → 열기**로 여세요.
   이 앱은 Apple 공증(notarization)을 받지 않았습니다. 유료 개발자 등록이
   필요한 절차이고, 학생이 학생에게 나눠 주는 도구라 두지 않았습니다.
   우클릭으로 한 번만 열면 그다음부터는 평소처럼 열립니다.

   그래도 열리지 않으면 터미널에서:
   xattr -dr com.apple.quarantine /Applications/SeoulLocalAgent.app

3. 브리핑을 쓰려면 Ollama가 필요합니다.
   brew install ollama && ollama serve

   앱의 설정 › 연결 상태를 열면 이 Mac에 맞는 모델 이름과
   받는 명령이 그대로 적혀 있습니다.

4. 전사·누끼·소리 다듬기·정밀 문서 인식은 파이썬 환경이 필요합니다.
   쓰고 싶은 것만 준비하면 되고, 앱 안에 설치 스크립트가 들어 있습니다.

   brew install uv
   /Applications/SeoulLocalAgent.app/Contents/Resources/scripts/setup-transcription-env.sh
   /Applications/SeoulLocalAgent.app/Contents/Resources/scripts/setup-matting-env.sh
   /Applications/SeoulLocalAgent.app/Contents/Resources/scripts/setup-media-env.sh
   /Applications/SeoulLocalAgent.app/Contents/Resources/scripts/setup-docparse-env.sh

   하나도 실행하지 않아도 문서 인식(빠름) · 스캔 보정 · PDF 편집 ·
   용량 줄이기 · 형식 변환 · 브리핑은 그대로 됩니다.

전체 안내: https://github.com/sesepark/snu-local-agent
TXT

/usr/bin/hdiutil create -volname "서울대 로컬 에이전트" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
/bin/rm -rf "$STAGE"

print ""
print "만들었습니다: $DMG"
/bin/ls -lh "$DMG" | /usr/bin/awk '{print "  크기:", $5}'
