#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-MusicAssistantMenuBar}"
PRODUCT_NAME="${PRODUCT_NAME:-MusicAssistantMenuBar}"
BUNDLE_ID="${BUNDLE_ID:-io.example.musicassistant.menubar}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_ICON_PATH="${APP_ICON_PATH:-$ROOT_DIR/Assets/AppIcon.icns}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
SIGNING_CERT_P12_BASE64="${SIGNING_CERT_P12_BASE64:-}"
SIGNING_CERT_PASSWORD="${SIGNING_CERT_PASSWORD:-}"
CI_KEYCHAIN_PASSWORD="${CI_KEYCHAIN_PASSWORD:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift is required" >&2
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign is required" >&2
  exit 1
fi

if [[ -n "$SIGNING_CERT_P12_BASE64" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "error: security tool is required to import signing certificate" >&2
    exit 1
  fi

  if [[ -z "$SIGNING_CERT_PASSWORD" ]]; then
    echo "error: SIGNING_CERT_PASSWORD is required when SIGNING_CERT_P12_BASE64 is set" >&2
    exit 1
  fi

  TMP_DIR="$(mktemp -d)"
  CERT_P12_PATH="$TMP_DIR/signing-cert.p12"
  KEYCHAIN_PATH="$TMP_DIR/ci-signing.keychain-db"
  KEYCHAIN_PASS="${CI_KEYCHAIN_PASSWORD:-$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)}"
  cleanup() {
    rm -rf "$TMP_DIR"
  }
  trap cleanup EXIT

  echo "==> Importing signing certificate into temporary keychain"
  if base64 --help 2>/dev/null | grep -q -- '--decode'; then
    echo "$SIGNING_CERT_P12_BASE64" | base64 --decode > "$CERT_P12_PATH"
  else
    echo "$SIGNING_CERT_P12_BASE64" | base64 -D > "$CERT_P12_PATH"
  fi

  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
  security import "$CERT_P12_PATH" -k "$KEYCHAIN_PATH" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" >/dev/null

  EXISTING_KEYCHAINS=()
  while IFS= read -r line; do
    EXISTING_KEYCHAINS+=("$line")
  done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"([^"]+)"$/\1/')
  security list-keychains -d user -s "$KEYCHAIN_PATH" "${EXISTING_KEYCHAINS[@]}" >/dev/null
  SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-$KEYCHAIN_PATH}"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  IDENTITY_CMD=(security find-identity -v -p codesigning)
  if [[ -n "$SIGNING_KEYCHAIN" ]]; then
    IDENTITY_CMD+=("$SIGNING_KEYCHAIN")
  fi

  AVAILABLE_IDENTITIES=()
  while IFS= read -r line; do
    AVAILABLE_IDENTITIES+=("$line")
  done < <("${IDENTITY_CMD[@]}" | awk -F\" '/\"/ {print $2}')

  for identity in "${AVAILABLE_IDENTITIES[@]}"; do
    if [[ "$identity" == Developer\ ID\ Application:* ]]; then
      SIGNING_IDENTITY="$identity"
      break
    fi
  done

  if [[ -z "$SIGNING_IDENTITY" && ${#AVAILABLE_IDENTITIES[@]} -gt 0 ]]; then
    SIGNING_IDENTITY="${AVAILABLE_IDENTITIES[0]}"
  fi

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "==> Auto-selected signing identity: $SIGNING_IDENTITY"
  fi
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "error: no signing identity found. Set SIGNING_IDENTITY or import a cert with SIGNING_CERT_P12_BASE64" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}.zip"

echo "==> Building $PRODUCT_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$PRODUCT_NAME"

if [[ -f "$APP_ICON_PATH" ]]; then
  cp "$APP_ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
else
  echo "warning: app icon not found at $APP_ICON_PATH; using default app icon" >&2
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Signing app with identity: $SIGNING_IDENTITY"
CODESIGN_ARGS=(
  --force
  --timestamp
  --options runtime
  --sign "$SIGNING_IDENTITY"
)

if [[ -n "$SIGNING_KEYCHAIN" ]]; then
  CODESIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
fi

codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Creating zip artifact"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required for notarization" >&2
    exit 1
  fi

  echo "==> Notarizing zip"

  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    if [[ -z "$APPLE_ID" || -z "$APPLE_APP_SPECIFIC_PASSWORD" || -z "$APPLE_TEAM_ID" ]]; then
      echo "error: notarization requires either NOTARY_PROFILE or APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID" >&2
      exit 1
    fi

    xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  fi

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$APP_DIR"

  echo "==> Repacking zip with stapled app"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
fi

echo "==> Done"
echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
