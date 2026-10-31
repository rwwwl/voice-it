#!/bin/zsh
# Build the app and wrap it in a signed bundle at build/<APP_NAME>.app (or $BUILD_DIR/<APP_NAME>.app).
# Environment: SHARED_BUILD=1 builds what is shared with others (no developer switches, no build-machine paths, stripped);
#              SIGN_IDENTITY_OVERRIDE="-" signs ad hoc whatever Config/app.env says; BUILD_DIR changes where everything goes.
# Identity, bundle ID and signing all come from Config/app.env; the version from VERSION; the build number and commit from git.
# Uses xcodebuild (MLX's Metal shaders can't be built by plain `swift build`; needs the Metal Toolchain component).
set -euo pipefail
cd "$(dirname "$0")/.."
source Config/app.env
SIGN_IDENTITY="${SIGN_IDENTITY_OVERRIDE:-$SIGN_IDENTITY}"
BUILD_DIR="${BUILD_DIR:-build}"
mkdir -p "$BUILD_DIR"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

if [[ "$SIGN_IDENTITY" == auto ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
  [[ -n "$IDENTITY" ]] || {
    echo "No \"Apple Development\" certificate found. Sign in with a free Apple ID in Xcode (Settings > Accounts)," >&2
    echo "or set SIGN_IDENTITY=\"-\" in Config/app.env for an ad hoc build (macOS then forgets granted permissions on every build)." >&2
    exit 1
  }
else
  IDENTITY="$SIGN_IDENTITY"
fi

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-modified"

# Hidden developer switches (--show-vocabulary, --selftest-*, ...) are built in by default. SHARED_BUILD=1 leaves them out.
DEV_CONDITION=DEV_TOOLS; [[ "${SHARED_BUILD:-0}" == 1 ]] && DEV_CONDITION=""

SETTINGS=(CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) $DEV_CONDITION")
SCHEMES=("$EXECUTABLE_NAME" voice-it-harness)
if [[ "${SHARED_BUILD:-0}" == 1 ]]; then
  # The compilers record the paths of the source files (in assertion messages, for one). Map this folder to a neutral name, so the shared
  # binary carries nothing about the machine or the user that built it. Only the app is built: the harness is a developer tool.
  ROOT=$PWD
  SETTINGS+=("OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$ROOT=/voice-it" "OTHER_CPLUSPLUSFLAGS=\$(inherited) -ffile-prefix-map=$ROOT=/voice-it" "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $ROOT=/voice-it")
  SCHEMES=("$EXECUTABLE_NAME")
fi

for scheme in $SCHEMES; do
  xcodebuild -scheme $scheme -configuration Release -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR/DerivedData" \
    -skipMacroValidation -skipPackagePluginValidation -quiet build "${SETTINGS[@]}" > "$BUILD_DIR/xcodebuild-$scheme.log" 2>&1 || {
    grep -E "error:|warning: unre|BUILD" "$BUILD_DIR/xcodebuild-$scheme.log" | head -20
    echo "Build failed for $scheme: nothing was packaged. Full output: $BUILD_DIR/xcodebuild-$scheme.log" >&2; exit 1
  }
  grep -E "warning: unre" "$BUILD_DIR/xcodebuild-$scheme.log" || true
done
PRODUCTS="$BUILD_DIR/DerivedData/Build/Products/Release"
# Never ship or run instrumented code: stop here if a binary has coverage instrumentation.
BINARIES=("$PRODUCTS/$EXECUTABLE_NAME"); [[ "${SHARED_BUILD:-0}" == 1 ]] || BINARIES+=("$PRODUCTS/voice-it-harness")
scripts/check_no_coverage.sh "${BINARIES[@]}" || { echo "Build refused: coverage instrumentation found (see above)." >&2; exit 1 }

APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/$EXECUTABLE_NAME" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
# A shared build drops the symbol and debug tables, which hold the paths of the build machine's object files.
[[ "${SHARED_BUILD:-0}" == 1 ]] && strip -S -x "$APP/Contents/MacOS/$EXECUTABLE_NAME"
sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@APP_NAME@|$APP_NAME|g" -e "s|@EXECUTABLE_NAME@|$EXECUTABLE_NAME|g" \
    -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" -e "s|@COMMIT@|$COMMIT|g" -e "s|@REPO_URL@|$REPO_URL|g" \
    -e "s|@COPYRIGHT_YEAR@|$COPYRIGHT_YEAR|g" -e "s|@COPYRIGHT_HOLDER@|$COPYRIGHT_HOLDER|g" \
    Resources/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# The app icon (built from the iconset with iconutil, so Finder always gets a valid file) and the menu bar icons (template images; the
# 1x, 2x and 3x files sit side by side and macOS picks the right one). Both come from design/icons.
iconutil -c icns design/icons/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
for state in idle recording blocked; do cp design/icons/MenuBar/MenuBar-$state.imageset/menubar-$state*.png "$APP/Contents/Resources/"; done
# The list of models the setup window can download (made by scripts/make-manifest.py).
cp Resources/models-manifest.json "$APP/Contents/Resources/"
# The licences travel with the app (the About window and the menu point at them).
cp LICENSE THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"
# SwiftPM resource bundles (MLX's compiled Metal shaders, tokenizer data, ...) sit next to the executable in a build.
for b in "$PRODUCTS"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
codesign --force --options runtime --entitlements Resources/VoiceIt.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP_NAME $VERSION (build $BUILD, $COMMIT)"
echo "Signed with: $IDENTITY"
codesign -dr - "$APP" 2>&1 | grep designated
