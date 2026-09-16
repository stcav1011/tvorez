#!/bin/sh
# Установка TVOREZ: кладёт скрипт в меню DaVinci Resolve и ставит yt-dlp + ffmpeg.
# Запуск из папки с репозиторием: sh install.sh
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"

mkdir -p "$DEST"
cp "$HERE/tvorez.lua" "$DEST/tvorez.lua"
echo "✓ Скрипт установлен: $DEST/tvorez.lua"

BREW=$(command -v brew || true)
[ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
[ -z "$BREW" ] && [ -x /usr/local/bin/brew ] && BREW=/usr/local/bin/brew

if [ -n "$BREW" ]; then
  echo "→ Ставлю yt-dlp и ffmpeg через Homebrew…"
  "$BREW" install yt-dlp ffmpeg
  echo "✓ Готово. Перезапусти DaVinci Resolve → Workspace → Scripts → tvorez"
else
  echo "! Homebrew не найден. Установи его с https://brew.sh и выполни:"
  echo "  brew install yt-dlp ffmpeg"
  echo "  Потом перезапусти DaVinci Resolve → Workspace → Scripts → tvorez"
fi
