#!/bin/zsh
# Builds dist/Tidemark-<version>-<lang>.zip, one archive per UI language.
# Universal binary (arm64 + x86_64), macOS 14 or later.
#
#   Scripts/build-release.sh            # en and ko
#   VERSION=1.1.0 Scripts/build-release.sh en
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${VERSION:-1.0.0}"
LANGS=("${@:-en}")
(( $# == 0 )) && LANGS=(en ko)
cd "$ROOT"
mkdir -p dist

for lang in $LANGS; do
  flags=()
  [[ $lang == ko ]] && flags=(-Xswiftc -DTIDEMARK_KO)
  args=(-c release --product Tidemark --arch arm64 --arch x86_64 --scratch-path ".build/$lang" $flags)
  swift build $args
  bin="$(swift build $args --show-bin-path)/Tidemark"

  app="dist/$lang/Tidemark.app"
  rm -rf "dist/$lang"
  mkdir -p "$app/Contents/MacOS"
  cp "$bin" "$app/Contents/MacOS/Tidemark"
  strip -x "$app/Contents/MacOS/Tidemark"
  sed -e "s/__VERSION__/$VERSION/g" -e "s/__REGION__/$lang/g" Packaging/Info.plist > "$app/Contents/Info.plist"
  mkdir -p "$app/Contents/Resources" && cp THIRD_PARTY_NOTICES.md LICENSE "$app/Contents/Resources/"
  codesign --force --sign - --identifier io.github.qualop.tidemark "$app"
  rm -f "dist/Tidemark-$VERSION-$lang.zip"
  ditto -c -k --keepParent "$app" "dist/Tidemark-$VERSION-$lang.zip"
  echo "dist/Tidemark-$VERSION-$lang.zip"
done
