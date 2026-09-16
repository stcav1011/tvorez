#!/bin/sh
# Установка TVOREZ: кладёт скрипт в меню DaVinci Resolve и ставит yt-dlp + ffmpeg.
# Из папки с репозиторием: sh install.sh
# Без скачивания репозитория:
#   curl -fsSL https://raw.githubusercontent.com/stcav1011/tvorez/main/install.sh | sh
set -e

RAW="https://raw.githubusercontent.com/stcav1011/tvorez/main"
DEST="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"

mkdir -p "$DEST"
if [ -f "$0" ] && [ -f "$(dirname "$0")/tvorez.lua" ]; then
  cp "$(dirname "$0")/tvorez.lua" "$DEST/tvorez.lua"
else
  echo "→ Скачиваю tvorez.lua с GitHub…"
  curl -fsSL "$RAW/tvorez.lua" -o "$DEST/tvorez.lua"
fi
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
