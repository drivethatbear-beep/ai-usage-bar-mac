#!/bin/zsh
# AI Usage 빌드 스크립트
#   ./build.sh            빌드 → .app 조립 → ad-hoc 서명 → ~/Applications 설치 → 실행
#   ./build.sh --package  Universal(arm64 + x86_64) 빌드 → dist/AI-Usage-macOS.zip 생성(설치 안 함)
set -euo pipefail
cd "$(dirname "$0")"

PACKAGE=false
[[ "${1:-}" == "--package" ]] && PACKAGE=true
# 로컬 전용 설정(git에 올리지 않음, 배포 빌드에서는 무시): 예) BUNDLE_ID=com.example.AIUsageBar
if ! $PACKAGE && [[ -f build.local.env ]]; then source build.local.env; fi
BUNDLE_ID="${BUNDLE_ID:-io.github.drivethatbear-beep.ai-usage-bar}"
VERSION="${VERSION:-1.0.1}"

if $PACKAGE; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AIUsageBar"
else
  swift build -c release
  BIN=".build/release/AIUsageBar"
fi

APP="build/AI Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AIUsageBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Usage</string>
  <key>CFBundleDisplayName</key><string>AI Usage</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>AIUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

if $PACKAGE; then
  mkdir -p dist
  rm -f dist/AI-Usage-macOS.zip
  ditto -c -k --norsrc --noextattr --keepParent "$APP" dist/AI-Usage-macOS.zip
  echo "패키지 완료: dist/AI-Usage-macOS.zip"
  lipo -archs "$APP/Contents/MacOS/AIUsageBar"
  exit 0
fi

DEST="$HOME/Applications/AI Usage.app"
pkill -x AIUsageBar 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "설치 완료: $DEST"
