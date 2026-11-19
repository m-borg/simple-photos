#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SimplePhotos"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME} (Release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
printf "APPL????" > "${CONTENTS_DIR}/PkgInfo"

echo "==> Generating AppIcon.icns..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
swift scripts/generate_icon.swift "${ICONSET_DIR}"
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "$(dirname "${ICONSET_DIR}")"

echo "==> Code-signing ${APP_BUNDLE} (ad-hoc)..."
codesign --force --deep --sign - "${APP_BUNDLE}"

# If installed in /Applications, keep it in sync automatically
if [ -d "/Applications/${APP_BUNDLE}" ]; then
    echo "==> Updating /Applications/${APP_BUNDLE}..."
    rm -rf "/Applications/${APP_BUNDLE}"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
fi

# Register with macOS LaunchServices so Finder's "Open With" sees Simple Photos
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "${LSREGISTER}" ]; then
    if [ -d "/Applications/${APP_BUNDLE}" ]; then
        "${LSREGISTER}" -u "${PWD}/${APP_BUNDLE}" || true
        "${LSREGISTER}" -f "/Applications/${APP_BUNDLE}" || true
    else
        "${LSREGISTER}" -f "${PWD}/${APP_BUNDLE}" || true
    fi
fi

echo "==> Done! Built: ${PWD}/${APP_BUNDLE}"
