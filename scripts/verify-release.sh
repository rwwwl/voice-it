#!/bin/zsh
# Checks a release zip the way a stranger's Mac would meet it, and says what it finds.
#   scripts/verify-release.sh build/release/dist/Voice-It-<version>-arm64.zip
# Set OFFLINE_RUN=0 to skip the last check (it opens the app for a few seconds with the network blocked; a setup window may appear).
set -uo pipefail
cd "$(dirname "$0")/.."
source Config/app.env
ZIP=${1:?usage: scripts/verify-release.sh <release zip>}
VERSION=$(tr -d '[:space:]' < VERSION)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null' EXIT
ditto -x -k "$ZIP" "$TMP"
APP="$TMP/$APP_NAME.app"; BIN="$APP/Contents/MacOS/$EXECUTABLE_NAME"
fail=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fail=1; }
note() { echo "  note $1"; }

echo "-- Signature"
codesign --verify --deep --strict "$APP" 2>/dev/null && ok "the signature is valid and the bundle is unmodified" || bad "the signature does not verify"
INFO=$(codesign -dvv "$APP" 2>&1)
echo "$INFO" | grep -q "Signature=adhoc" && ok "signed ad hoc (no certificate), as intended" || bad "not signed ad hoc"
echo "$INFO" | grep -q "flags=.*runtime" && ok "hardened runtime is on" || bad "hardened runtime is off"
codesign -dr - "$APP" 2>&1 | grep -q 'designated => cdhash H"' && ok "its identity is the hash of this exact build (so macOS asks for the permissions again after every update)" || bad "unexpected designated requirement"
ENT=$(codesign -d --entitlements - "$APP" 2>/dev/null | strings)
[[ $(echo "$ENT" | grep -c "com.apple.") == 1 && "$ENT" == *device.audio-input* ]] && ok "the only entitlement is microphone input" || bad "unexpected entitlements: $ENT"

echo "-- What it is"
[[ "$(lipo -archs "$BIN")" == arm64 ]] && ok "Apple silicon only (arm64)" || bad "architectures: $(lipo -archs "$BIN")"
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]] && ok "version $VERSION" || bad "the version in Info.plist is not $VERSION"
[[ "$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")" == 15.0 ]] && ok "needs macOS 15.0 or later" || bad "minimum macOS is not 15.0"
[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] && ok "bundle identifier $BUNDLE_ID" || bad "bundle identifier differs from Config/app.env"
for f in AppIcon.icns LICENSE THIRD_PARTY_LICENSES.md models-manifest.json menubar-idle.png; do [[ -e "$APP/Contents/Resources/$f" ]] && ok "has $f" || bad "missing $f"; done
BIG=$(find "$APP" -type f -size +60M | head -1)
[[ -z "$BIG" && -z "$(find "$APP" \( -name '*.mlmodelc' -o -name '*.safetensors' -o -name '*.wav' \) | head -1)" ]] && ok "no model and no audio inside the app ($(du -sh "$APP" | cut -f1) in all)" || bad "a model, audio or a very large file is inside the app: $BIG"
EXTRA=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/System/Library|/usr/lib|@rpath)' || true)
[[ -z "$EXTRA" ]] && ok "links only system libraries" || bad "links something unexpected: $EXTRA"

echo "-- Nothing of the build machine or the developer's tools"
LEAK=$(strings "$BIN" | grep -E "/Users/|/Volumes/|$USER|$(hostname -s)" | head -3)
[[ -z "$LEAK" ]] && ok "no home folder, user name or machine name in the program" || bad "personal details in the program: $LEAK"
SWITCH=$(strings "$BIN" | grep -E -- "--selftest|--show-vocabulary|--show-setup|--render-setup|--simulate-|--preview-all|--setup-auto" | head -3)
[[ -z "$SWITCH" ]] && ok "no hidden developer switches" || bad "developer switches are built in: $SWITCH"
otool -l "$BIN" | grep -q "__llvm_prf" && bad "code-coverage instrumentation is present" || ok "no code-coverage instrumentation"
PERS=$(grep -rIl -E "/Users/|$USER" "$APP" 2>/dev/null | head -3)
[[ -z "$PERS" ]] && ok "no personal path in any text file inside the app" || bad "personal paths in: $PERS"

echo "-- What macOS will say to a stranger (the honest part)"
cp -R "$APP" "$TMP/quarantined.app"
xattr -w com.apple.quarantine "0083;$(printf '%x' $(date +%s));Safari;" "$TMP/quarantined.app"
GK=$(spctl --assess --type execute -vv "$TMP/quarantined.app" 2>&1 | head -2 | tr '\n' ' ')
note "Gatekeeper on a quarantined copy says: ${GK:-nothing}"
note "that is expected: this app is not notarised, so a person approves it once in System Settings, Privacy & Security, Open Anyway"

if [[ "${OFFLINE_RUN:-1}" == 1 ]]; then
  echo "-- Does it run with no network at all?"
  MODELS=""
  for c in "${VOICEIT_MODELS_SOURCE:-}" "$HOME/Library/Application Support/Voice It/models" "$HOME/Library/Application Support/Voice It.backup/models"; do
    [[ -n "$c" && -f "$c/cleanup/Qwen3-4B-Instruct-2507-4bit/model.safetensors" && -f "$c/parakeet-tdt-0.6b-v2/Encoder.mlmodelc/weights/weight.bin" ]] && { MODELS=$c; break; }
  done
  if [[ -z "$MODELS" ]]; then note "no complete set of models on this Mac, so the offline run is skipped (VOICEIT_MODELS_SOURCE=<models folder> points at one)"
  else
    SUPPORT=$(mktemp -d); ln -s "$MODELS" "$SUPPORT/models"
    LOG="$HOME/Library/Logs/Voice It/voice-it.log"; N0=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    VOICEIT_SUPPORT_DIR=$SUPPORT sandbox-exec -f scripts/no-network.sb "$BIN" >/dev/null 2>&1 & APP_PID=$!
    READY=""
    for i in $(seq 1 60); do
      READY=$(tail -n +$((N0+1)) "$LOG" 2>/dev/null | grep -E "cleanup model ready|models ready" | tail -1)
      echo "$READY" | grep -q "models ready" && break
      sleep 1
    done
    kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
    echo "$READY" | grep -q "models ready" && ok "with the network blocked it loaded both models and was ready: ${READY#* }" || bad "it did not become ready offline"
    rm -rf "$SUPPORT"
  fi
fi

echo
[[ $fail == 0 ]] && echo "All checks passed." || { echo "Some checks FAILED." >&2; exit 1; }
