#!/bin/zsh
# Creates a self-contained local .app bundle; no launch agent or login item is installed.
set -eu

# 이 스크립트가 놓인 자리에서 구한다. 다른 사람이 어디에 내려받아도 그대로 돈다.
PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/SeoulLocalAgent.app"
ICONSET="$PROJECT_DIR/dist/SeoulLocalAgent.iconset"

cd "$PROJECT_DIR"
/usr/bin/swift build -c release
/bin/rm -rf "$APP_DIR"
/bin/rm -rf "$ICONSET"
/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
/bin/cp ".build/release/SeoulLocalAgent" "$APP_DIR/Contents/MacOS/SeoulLocalAgent"
/bin/cp -R ".build/release/SeoulLocalAgent_SeoulLocalAgent.bundle" "$APP_DIR/Contents/Resources/"
/bin/mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$PROJECT_DIR/Assets/SeoulUniversityLogo.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z "$((size * 2))" "$((size * 2))" "$PROJECT_DIR/Assets/SeoulUniversityLogo.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/SeoulLocalAgent.icns"
/bin/cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SeoulLocalAgent</string>
  <key>CFBundleIdentifier</key><string>kr.ac.snu.local-agent</string>
  <key>CFBundleIconFile</key><string>SeoulLocalAgent</string>
  <key>CFBundleName</key><string>서울대 로컬 에이전트</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSMicrophoneUsageDescription</key><string>회의와 강의를 녹음해 이 기기에서 전사하기 위해 마이크를 사용합니다.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>인박스 정리에 앞으로의 일정을 포함하고, 브리핑 보관함에서 고른 항목만 '서울대 로컬 에이전트' 전용 캘린더에 넣기 위해 캘린더에 접근합니다.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>브리핑 보관함에서 고른 항목을 '서울대 로컬 에이전트' 전용 목록에 미리 알림으로 넣기 위해 접근합니다.</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The SO-ARM console is reached over an SSH tunnel to 127.0.0.1 and speaks
       plain HTTP; ATS would otherwise block both the status polling and the
       embedded web console. This permits loopback and local networking only. -->
  <!-- The robot console runs on a machine on the home LAN and is reached by an
       SSH tunnel, so macOS asks for local-network access the first time. Without
       this string the prompt cannot say what the app wants it for. -->
  <key>NSLocalNetworkUsageDescription</key><string>집 서버의 SO-ARM101 콘솔에 SSH 터널로 연결하기 위해 같은 네트워크의 그 서버에만 접속합니다. 다른 기기를 찾거나 수집하지 않습니다.</string>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_DIR"
echo "Created: $APP_DIR"
