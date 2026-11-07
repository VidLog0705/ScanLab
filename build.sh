#!/usr/bin/env bash
# 出 ScanLab 未签名 .ipa。只在 macOS 上跑（CI 是 macos-15）。
# 本机是 Windows，**编不了** —— 第一次编译就发生在 GitHub Actions 上。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

command -v xcodegen >/dev/null || { echo "缺 xcodegen：brew install xcodegen"; exit 1; }

xcodegen generate --quiet

xcodebuild \
  -project ScanLab.xcodeproj \
  -scheme ScanLab \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="build/Build/Products/Release-iphoneos/ScanLab.app"
if [ ! -d "$APP" ]; then
  echo "找不到 $APP"
  exit 1
fi

# 产物都放 build/ 下面 —— 那里本来就不进 git
rm -rf build/ipa build/ScanLab-unsigned.ipa
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
# 未签名包：去掉 _CodeSignature，免得 Sideloadly 因签名残留报错
rm -rf build/ipa/Payload/ScanLab.app/_CodeSignature

(cd build/ipa && zip -qry ../ScanLab-unsigned.ipa Payload)
ls -lh build/ScanLab-unsigned.ipa
echo "OK: $HERE/build/ScanLab-unsigned.ipa"
