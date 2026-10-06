#!/bin/zsh
# Builds Cadence.app into ./build and signs it with a stable local identity, so macOS
# keeps the Accessibility/Microphone grants across rebuilds (ad-hoc signatures reset them).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Cadence.app
IDENTITY="Murmur Local Signing"
KEYCHAIN="$HOME/Library/Keychains/murmur-signing.keychain-db"
# The keychain's password is generated per machine and kept outside the repo.
PASS_FILE="$HOME/.config/cadence/signing-keychain-password"
if [[ ! -f "$PASS_FILE" ]]; then
  mkdir -p "$(dirname "$PASS_FILE")" && chmod 700 "$(dirname "$PASS_FILE")"
  openssl rand -hex 24 > "$PASS_FILE" && chmod 600 "$PASS_FILE"
fi
KEYCHAIN_PASS="$(cat "$PASS_FILE")"

echo "→ Compiling (release)…"
swift build -c release

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Cadence "$APP/Contents/MacOS/Cadence"
for b in .build/release/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cadence</string>
  <key>CFBundleDisplayName</key><string>Cadence</string>
  <key>CFBundleIdentifier</key><string>com.vinit.cadence</string>
  <key>CFBundleExecutable</key><string>Cadence</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSAudioCaptureUsageDescription</key><string>While you dictate, Cadence muffles other apps' audio so you can focus. Nothing is recorded or stored.</string>
  <key>NSMicrophoneUsageDescription</key><string>Cadence listens only while you hold your dictation key, and transcribes on this Mac.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# One-time: a self-signed code-signing identity in its own keychain (never touches the login keychain's items).
if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "→ Creating local signing identity"
  TMP=$(mktemp -d)
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:cadence 2>/dev/null \
    || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:cadence
  [[ -f "$KEYCHAIN" ]] || security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security import "$TMP/id.p12" -k "$KEYCHAIN" -P cadence -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
  rm -rf "$TMP"
fi

echo "→ Signing"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
codesign --force --deep --keychain "$KEYCHAIN" -s "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP"
echo "✓ Built $APP"
