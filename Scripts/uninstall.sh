#!/bin/zsh
# Quit Tidemark and remove the app and its settings.
set -euo pipefail
pkill -x Tidemark 2>/dev/null || true
rm -rf "/Applications/Tidemark.app" "$HOME/Applications/Tidemark.app"
rm -rf "$HOME/Library/Application Support/Tidemark"
echo "Tidemark removed. If it is still listed under System Settings > General > Login Items, remove it there."
