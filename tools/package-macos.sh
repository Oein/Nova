#!/usr/bin/env bash
#
# Build Nova.app and wrap it in a .dmg.
#
# Must run on macOS: `hdiutil` is the only tool that writes a disk image Finder
# will mount, and linking SDL needs Apple's frameworks, which ship with Xcode
# and are not redistributable. Everything up to that point -- the binary, the
# bundle layout, the Info.plist -- is built by `zig build bundle` and works on
# any host.
#
#   ./tools/package-macos.sh                 # host architecture
#   ARCH=aarch64 ./tools/package-macos.sh    # Apple Silicon
#   ARCH=x86_64  ./tools/package-macos.sh    # Intel
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)"
ARCH="${ARCH:-$(uname -m)}"
[ "$ARCH" = "arm64" ] && ARCH=aarch64

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: this must run on macOS." >&2
  echo "  Linking SDL needs Apple's frameworks (Cocoa, Metal, CoreVideo, ...)," >&2
  echo "  which only come with Xcode, and hdiutil is macOS-only." >&2
  echo "  Push a v* tag, or run the 'Release' workflow, to have CI build it." >&2
  exit 1
fi

OUT="dist"
DMG="$OUT/Nova-$VERSION-$ARCH.dmg"
STAGE="$OUT/stage"

echo "==> Building Nova $VERSION for $ARCH"
zig build bundle -Doptimize=ReleaseFast -Dtarget="$ARCH-macos"

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R zig-out/Nova.app "$STAGE/"
# The /Applications alias is what makes the window a drag-to-install target.
ln -s /Applications "$STAGE/Applications"

# Ad-hoc signing. Not notarization -- the first launch still needs
# right-click > Open -- but it stops macOS reporting the app as damaged, which
# is what an entirely unsigned bundle gets on Apple Silicon.
if command -v codesign >/dev/null; then
  echo "==> Signing (ad-hoc)"
  codesign --force --deep --sign - "$STAGE/Nova.app"
fi

echo "==> Creating $DMG"
hdiutil create \
  -volname "Nova $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

rm -rf "$STAGE"
echo
echo "==> $DMG"
ls -lh "$DMG" | awk '{print "    " $5}'
