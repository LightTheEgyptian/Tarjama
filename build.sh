#!/bin/bash
# Builds Tarjama.app from source and installs it into Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Tarjama.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Compiling…"
xcrun swiftc -swift-version 5 -O Sources/*.swift -o "$APP/Contents/MacOS/Tarjama"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tarjama</string>
<key>CFBundleIdentifier</key><string>com.nurelmasri.tarjama</string>
<key>CFBundleName</key><string>Tarjama</string>
<key>CFBundleDisplayName</key><string>Tarjama</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSServices</key>
<array>
  <dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Translate with Tarjama</string></dict>
    <key>NSMessage</key><string>translateText</string>
    <key>NSPortName</key><string>Tarjama</string>
    <key>NSSendTypes</key><array><string>NSStringPboardType</string><string>public.utf8-plain-text</string></array>
    <key>NSRequiredContext</key><dict/>
  </dict>
</array>
</dict></plist>
PLIST
# App icon
if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign with a stable local certificate, so macOS remembers the Accessibility
# permission across rebuilds (an ad-hoc signature changes every build).
IDENTITY="Nur Local Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
NEWCERT=0
if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Creating a local signing certificate (one time only)…"
  TMP=$(mktemp -d)
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:local -name "$IDENTITY"
  security import "$TMP/id.p12" -k "$KEYCHAIN" -P local -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"
  NEWCERT=1
fi
STABLE=1
if ! codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "macOS needs to trust the local certificate for signing. Enter your Mac password if asked."
  PEM=$(mktemp)
  security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$PEM"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$PEM" || true
  rm -f "$PEM"
  codesign --force --sign "$IDENTITY" "$APP" || { echo "Falling back to ad-hoc signing."; codesign --force --sign - "$APP"; STABLE=0; }
fi
codesign -dv "$APP" 2>&1 | grep -E "Authority|Signature" || true
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x Tarjama 2>/dev/null || true
# Clear the old permission entry when the signature changes, so macOS asks fresh once.
if [ "$NEWCERT" = "1" ] || [ ! -f .signed-stable ] || [ "$STABLE" = "0" ]; then
  tccutil reset Accessibility com.nurelmasri.tarjama >/dev/null 2>&1 || true
  echo "Accessibility permission reset: allow Tarjama once more when asked."
fi
if [ "$STABLE" = "1" ]; then touch .signed-stable; else rm -f .signed-stable 2>/dev/null || true; fi
sleep 0.5
rm -rf "$DEST/Tarjama.app"
cp -R "$APP" "$DEST/"
/System/Library/CoreServices/pbs -update 2>/dev/null || true
open "$DEST/Tarjama.app"
echo "Installed: $DEST/Tarjama.app"
