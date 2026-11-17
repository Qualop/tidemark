#!/bin/zsh
# Build from source for this Mac and install to ~/Applications/Tidemark.app.
#
#   Scripts/install.sh       # English UI
#   Scripts/install.sh ko    # Korean UI
set -euo pipefail

ROOT="${0:A:h:h}"
UI_LANG="${1:-en}"
APP="$HOME/Applications/Tidemark.app"
cd "$ROOT"

flags=()
[[ $UI_LANG == ko ]] && flags=(-Xswiftc -DTIDEMARK_KO)
swift build -c release --product Tidemark $flags
BIN="$(swift build -c release --product Tidemark $flags --show-bin-path)/Tidemark"

pkill -x Tidemark 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Tidemark"
strip -x "$APP/Contents/MacOS/Tidemark"
sed -e "s/__VERSION__/dev/g" -e "s/__REGION__/$UI_LANG/g" Packaging/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - --identifier io.github.qualop.tidemark "$APP"
open "$APP"
echo "Installed $APP"
