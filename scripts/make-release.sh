#!/bin/zsh
# Builds the app that is shared with others, packages it, and checks it.
#   scripts/make-release.sh
# Produces build/release/dist/ (and keeps a copy in releases/<version>-<commit>/):
#   Voice-It-<version>-arm64.zip   the app, for people who download it
#   Voice-It-<version>-arm64.dmg   the same app with an Applications shortcut to drag it onto
#   SHA256SUMS.txt                 the checksum of each file
#   RELEASE_NOTES.md               the release notes, with the checksums filled in (from docs/release-notes-template.md and docs/WHATS_NEW.md)
#
# What it does, in order: refuses to run unless everything is committed (a release must be reproducible from a commit); runs the unit tests;
# builds a SHARED_BUILD (no developer switches, no build-machine paths, symbols stripped) signed AD HOC (no certificate: this project has no
# paid Apple Developer membership, so the app is not notarised and macOS asks the person to approve it once); packages it; and runs
# scripts/verify-release.sh on the result. It never claims the app is notarised or verified by Apple.
# Environment: ALLOW_DIRTY=1 (try it with uncommitted changes; the result must not be shared), SKIP_TESTS=1, OFFLINE_RUN=0 (skip the offline run).
set -euo pipefail
cd "$(dirname "$0")/.."
source Config/app.env
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
VERSION=$(tr -d '[:space:]' < VERSION)
OUT=build/release
DIST=$OUT/dist
NAME="Voice-It-$VERSION-arm64"

if [[ "${ALLOW_DIRTY:-0}" != 1 && -n "$(git status --porcelain)" ]]; then
  echo "Refusing to build a release: there are uncommitted changes. Commit them first (or ALLOW_DIRTY=1 for a trial run that must not be shared):" >&2
  git status --short >&2; exit 1
fi

if [[ "${SKIP_TESTS:-0}" != 1 ]]; then
  echo "== Unit tests"
  TESTS=$(swift test 2>&1 || true)
  echo "$TESTS" | grep -E "Test run with|error:|✘" || true
  echo "$TESTS" | grep -q "Test run with .* passed" || { echo "The unit tests do not pass: no release." >&2; exit 1; }
fi

echo "== Building (shared build, ad hoc signature)"
BUILD_DIR=$OUT SHARED_BUILD=1 SIGN_IDENTITY_OVERRIDE=- scripts/build.sh
APP="$OUT/$APP_NAME.app"

echo "== Packaging"
rm -rf "$DIST"; mkdir -p "$DIST"
# ditto keeps the resource forks and permissions macOS needs; plain `zip` can damage an app bundle.
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"                       # the shortcut to drag the app onto
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)

# The release notes for GitHub: the template, this version's news (docs/WHATS_NEW.md) and the checksums just made.
python3 - "$VERSION" "$(git rev-parse --short HEAD)" "$DIST" <<'PY'
import sys
version, commit, dist = sys.argv[1:]
text = open("docs/release-notes-template.md").read()
text = text.replace("{VERSION}", version).replace("{COMMIT}", commit).replace("{WHATS_NEW}", open("docs/WHATS_NEW.md").read().strip()).replace("{CHECKSUMS}", open(dist + "/SHA256SUMS.txt").read().strip())
open(dist + "/RELEASE_NOTES.md", "w").write(text)
PY

echo "== Checking the disk image"
MOUNT=$(mktemp -d)
detach_image() {
  # Spotlight or Finder can still be looking at the volume for a moment ("Resource busy"): wait and try again, then force it.
  for attempt in 1 2 3 4 5 6 7 8; do
    hdiutil detach "$MOUNT" >/dev/null 2>&1 && return 0
    sleep 2
  done
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 && return 0
  echo "  note: the disk image is still mounted at $MOUNT; eject it in Finder" >&2
  return 0
}
# Right after the image is made hdiutil sometimes answers "Resource temporarily unavailable": wait a moment and try again.
for attempt in 1 2 3 4 5 6; do
  hdiutil attach "$DIST/$NAME.dmg" -nobrowse -readonly -noverify -mountpoint "$MOUNT" >/dev/null 2>&1 && break
  [[ $attempt == 6 ]] && { echo "  FAIL the disk image would not mount" >&2; exit 1; }
  sleep 3
done
[[ -d "$MOUNT/$APP_NAME.app" && -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]] \
  && echo "  ok   the disk image holds $APP_NAME.app and the Applications shortcut" || { echo "  FAIL the disk image is not laid out as expected" >&2; detach_image; exit 1; }
codesign --verify --deep --strict "$MOUNT/$APP_NAME.app" && echo "  ok   the app inside the disk image has a valid signature"
detach_image; rmdir "$MOUNT" 2>/dev/null || true

echo "== Verifying the zip"
scripts/verify-release.sh "$DIST/$NAME.zip"

# Keep every release: build/ can be cleaned or rebuilt at any time, so each finished set is also copied to releases/<version>-<commit>/
# (inside the project, ignored by git). A trial run from uncommitted changes is kept apart, marked -trial.
ARCHIVE="releases/$VERSION-$(git rev-parse --short HEAD)"
[[ -n "$(git status --porcelain)" ]] && ARCHIVE="$ARCHIVE-trial"
mkdir -p "$ARCHIVE" && cp -p "$DIST"/* "$ARCHIVE"/ && echo "== Kept a copy in $ARCHIVE"

echo
echo "== Done: $DIST"
ls -l "$DIST" | tail -n +2
echo; cat "$DIST/SHA256SUMS.txt"
