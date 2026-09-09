#!/bin/zsh
# Installs the high-fidelity route for 한글 문서 (HWP·HWPX).
#
# The app reads 한글 문서 on its own — no install needed — but it re-typesets
# them, so the page breaks and the layout are its own rather than 한글's. This
# script sets up the route that keeps the original layout:
#
#   LibreOffice      the converter that produces the PDF
#   Java runtime     H2Orestart is a Java filter and will not load without one
#   H2Orestart       the import filter that reads HWP 5.x and HWPX
#
# LibreOffice's own `hwpfilter` is not enough: it only understands HWP 3.0 from
# 1997, and every document a Korean university actually sends out is HWP 5.x or
# HWPX. H2Orestart (GPL, https://github.com/ebandal/H2Orestart) is what fills
# that gap, and it is the same filter the Debian and Fedora packages ship.
#
# Once this finishes, 형식 변환 and 인쇄 pick the new route up by themselves.
set -eu

VERSION="${H2ORESTART_VERSION:-0.7.14}"
SOFFICE="/Applications/LibreOffice.app/Contents/MacOS/soffice"
UNOPKG="/Applications/LibreOffice.app/Contents/MacOS/unopkg"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew를 찾지 못했습니다. https://brew.sh 에서 먼저 설치해 주세요." >&2
  exit 1
fi

if [ ! -x "$SOFFICE" ]; then
  echo "LibreOffice를 설치합니다. (약 1 GB, 몇 분 걸립니다)"
  brew install --cask libreoffice
else
  echo "LibreOffice: 이미 설치되어 있습니다."
fi

# LibreOffice needs a JDK it can see; the stub at /usr/bin/java is not one.
if /usr/libexec/java_home >/dev/null 2>&1; then
  echo "Java: $(/usr/libexec/java_home)"
else
  echo "Java 런타임을 설치합니다."
  brew install --cask temurin
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OXT="$WORK/H2Orestart.oxt"

echo "H2Orestart $VERSION을 내려받습니다."
curl -fL --retry 3 -o "$OXT" \
  "https://github.com/ebandal/H2Orestart/releases/download/v$VERSION/H2Orestart.oxt"

# Reinstalling over an older copy is what `unopkg add -f` is for; without the
# flag it refuses when a version is already there.
"$UNOPKG" add -f "$OXT"

echo
echo "끝났습니다. 확인:"
"$UNOPKG" list | grep -i -A 2 h2orestart || true
echo
echo "이제 앱의 형식 변환·인쇄가 HWP와 HWPX를 원본 서식 그대로 PDF로 만듭니다."
echo "설치를 되돌리려면: $UNOPKG remove H2Orestart.oxt"
