#!/bin/zsh
# `swift test` silently runs zero tests when xcode-select points at the Command
# Line Tools, because that toolchain ships no `xctest` runner: it prints
# "Build complete!" and exits 0 with nothing executed. Point SwiftPM at the full
# Xcode toolchain when one is installed so the suite actually runs.
set -euo pipefail

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! /usr/bin/xcrun --find xctest >/dev/null 2>&1; then
  print -u2 "xctest를 찾지 못했습니다. Xcode를 설치했는지, DEVELOPER_DIR가 올바른지 확인하세요."
  exit 1
fi

exec /usr/bin/swift test "$@"
