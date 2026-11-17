#!/bin/zsh
# Builds dist/Tidemark-<version>-<lang>.zip, one archive per UI language.
# Universal binary: arm64 runs on macOS 12+, x86_64 on macOS 14+.
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
  slices=()
  for spec in arm64:12.0 x86_64:14.0; do
    arch=${spec%%:*}
    minos=${spec##*:}
    args=(-c release --product Tidemark --triple "$arch-apple-macosx$minos" --scratch-path ".build/$lang-$arch" $flags)
    swift build $args
    slices+=("$(swift build $args --show-bin-path)/Tidemark")
  done

  app="dist/$lang/Tidemark.app"
  rm -rf "dist/$lang"
  mkdir -p "$app/Contents/MacOS"
  lipo -create $slices -output "$app/Contents/MacOS/Tidemark"
  strip -x "$app/Contents/MacOS/Tidemark"
  sed -e "s/__VERSION__/$VERSION/g" -e "s/__REGION__/$lang/g" Packaging/Info.plist > "$app/Contents/Info.plist"
  codesign --force --sign - --identifier io.github.qualop.tidemark "$app"
  rm -f "dist/Tidemark-$VERSION-$lang.zip"
  ditto -c -k --keepParent "$app" "dist/Tidemark-$VERSION-$lang.zip"
  echo "dist/Tidemark-$VERSION-$lang.zip"
done
