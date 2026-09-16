--[[
  TVOREZ · загрузчик медиа для DaVinci Resolve (macOS)
  Меню: Workspace → Scripts → tvorez

  Качает видео и звук по ссылкам (YouTube, Instagram, TikTok, VK, Vimeo
  и ещё ~1800 сайтов) через yt-dlp в рабочую папку и сразу кладёт файлы
  в Media Pool открытого проекта.

  Нужно: brew install yt-dlp ffmpeg
  Данные: ~/.tvorez — настройки, история и графика интерфейса
]]

local VERSION = "2.0"

local resolve = resolve or bmd.scriptapp("Resolve")
local fu = fu or fusion or resolve:Fusion()

local HOME = os.getenv("HOME")
local DATA_DIR = HOME .. "/.tvorez"
local SETTINGS_FILE = DATA_DIR .. "/settings"
local HISTORY_FILE = DATA_DIR .. "/history.tsv"
local ASSETS_DIR = DATA_DIR .. "/ui-" .. VERSION
local DEFAULT_DIR = HOME .. "/Movies/tvorez"
local HISTORY_LIMIT = 200
local WINDOW_FLAGS = nil

local ASSETS -- графика интерфейса в base64, заполняется в конце файла

-------------------------------------------------------------------------------
-- Утилиты
-------------------------------------------------------------------------------

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

local function firstExisting(paths)
  for _, p in ipairs(paths) do
    if fileExists(p) then return p end
  end
end

-- Путь из opt/ идёт первым: это всегда версия от Homebrew, даже если
-- bin/yt-dlp перезаписан pip-установкой.
local YTDLP = firstExisting({
  "/opt/homebrew/opt/yt-dlp/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp",
  "/usr/local/opt/yt-dlp/bin/yt-dlp", "/usr/local/bin/yt-dlp",
})
local FFMPEG = firstExisting({ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" })
local BREW = firstExisting({ "/opt/homebrew/bin/brew", "/usr/local/bin/brew" })

local function sh(s)
  return "'" .. (tostring(s):gsub("'", [['\'']])) .. "'"
end

local function run(cmd)
  local p = io.popen(cmd)
  local out = p:read("*a")
  p:close()
  return out
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeFile(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

local function mkdir(path)
  os.execute("mkdir -p " .. sh(path))
end

local function splitLines(s)
  local t = {}
  for l in (s or ""):gmatch("[^\r\n]+") do t[#t + 1] = l end
  return t
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function oneLine(s)
  return (tostring(s or ""):gsub("[\t\r\n]+", " "))
end

local function shortPath(path)
  if path:sub(1, #HOME) == HOME then return "~" .. path:sub(#HOME + 1) end
  return path
end

-- Последние n символов строки UTF-8 с «…» в начале.
local function tail(s, n)
  local chars = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  if #chars <= n then return s end
  return "…" .. table.concat(chars, "", #chars - n + 2)
end

local function ytdlpVersion()
  return trim(run("readlink /opt/homebrew/opt/yt-dlp /usr/local/opt/yt-dlp 2>/dev/null")):match("yt%-dlp/([%d%.]+)")
end

local function ensureAssets()
  mkdir(ASSETS_DIR)
  for name, data in pairs(ASSETS) do
    local path = ASSETS_DIR .. "/" .. name
    if not fileExists(path) then
      writeFile(path .. ".b64", data)
      os.execute(("base64 -D -i %s -o %s; rm -f %s"):format(sh(path .. ".b64"), sh(path), sh(path .. ".b64")))
    end
  end
end

-------------------------------------------------------------------------------
-- Настройки и история
-------------------------------------------------------------------------------

local DEFAULTS = {
  dir = DEFAULT_DIR, perProject = "1", mode = "0", quality = "0",
  bin = "Из интернета", timeline = "0", cookies = "0", playlist = "0",
}

local function loadSettings()
  local s = {}
  for k, v in pairs(DEFAULTS) do s[k] = v end
  for _, l in ipairs(splitLines(readFile(SETTINGS_FILE))) do
    local k, v = l:match("^(%w+)=(.*)$")
    if k then s[k] = v end
  end
  return s
end

local function saveSettings(s)
  local out = {}
  for k, v in pairs(s) do out[#out + 1] = k .. "=" .. tostring(v) end
  table.sort(out)
  mkdir(DATA_DIR)
  writeFile(SETTINGS_FILE, table.concat(out, "\n") .. "\n")
end

local HISTORY_FIELDS = { "id", "when", "title", "dur", "fmt", "site", "path" }

local function loadHistory()
  local list = {}
  for _, l in ipairs(splitLines(readFile(HISTORY_FILE))) do
    local e, i = {}, 1
    for v in (l .. "\t"):gmatch("(.-)\t") do
      if HISTORY_FIELDS[i] then e[HISTORY_FIELDS[i]] = v end
      i = i + 1
    end
    if e.path then list[#list + 1] = e end
  end
  return list
end

local function saveHistory(list)
  local out = {}
  for i = math.max(1, #list - HISTORY_LIMIT + 1), #list do
    local row = {}
    for j, k in ipairs(HISTORY_FIELDS) do row[j] = oneLine(list[i][k]) end
    out[#out + 1] = table.concat(row, "\t")
  end
  mkdir(DATA_DIR)
  writeFile(HISTORY_FILE, table.concat(out, "\n") .. "\n")
end

-------------------------------------------------------------------------------
-- Загрузка (yt-dlp работает в фоне, окно Resolve не зависает)
-------------------------------------------------------------------------------

local MODE_AV, MODE_VIDEO, MODE_AUDIO = 1, 2, 3
local MODES = { "ВИДЕО + ЗВУК  ·  MP4", "ТОЛЬКО ВИДЕО  ·  БЕЗ ЗВУКА", "ТОЛЬКО ЗВУК  ·  WAV" }

local QUALITIES = {
  { label = "1080p  ·  H.264  ·  рекомендую", height = 1080 },
  { label = "720p  ·  H.264  ·  лёгкие файлы", height = 720 },
  { label = "МАКСИМУМ  ·  до 4K  ·  AV1", height = nil },
}

local BROWSERS = { "не использовать", "chrome", "safari", "firefox", "brave", "edge", "opera", "vivaldi" }

-- H.264 + AAC в MP4 Resolve открывает везде и без тормозов. 4K YouTube
-- отдаёт только в AV1/VP9, поэтому для «Максимума» берём AV1.
local function formatArgs(mode, quality)
  if mode == MODE_AUDIO then
    return { "-f", "ba/b", "-x", "--audio-format", "wav" }
  end
  local audio = mode == MODE_AV
  local h = QUALITIES[quality].height
  if not h then
    return { "-f", audio and "bv*+ba/b" or "bv*/b", "-S", "res,fps,hdr:SDR,vcodec:av01,acodec:aac", "--merge-output-format", "mp4" }
  end
  local c = "[height<=" .. h .. "]"
  local chain
  if audio then
    chain = {
      "bv*[vcodec^=avc1]" .. c .. "+ba[acodec^=mp4a]", "bv*[vcodec^=avc1]" .. c .. "+ba",
      "b[vcodec^=avc1]" .. c, "bv*" .. c .. "+ba", "b" .. c, "bv*+ba", "b",
    }
  else
    chain = { "bv*[vcodec^=avc1]" .. c, "bv*" .. c, "b" .. c, "bv*", "b" }
  end
  return { "-f", table.concat(chain, "/"), "--merge-output-format", "mp4" }
end

local META_TEMPLATE = "after_move:%(filepath)s\t%(title)s\t%(duration_string|—)s\t%(height&{}p|)s\t%(extractor_key)s"

local DOWNLOAD_SH = [==[
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LIST="$JOB/downloaded.txt"
READY="$JOB/ready.txt"
: > "$LIST"; : > "$READY"
"$YTDLP" "$@" --print-to-file after_move:filepath "$LIST" --print-to-file "$META" "$JOB/meta.txt" -a "$JOB/urls.txt"
rc=$?

# Приводим файлы к виду, который Resolve точно откроет:
# VP9 и прочую экзотику — в HEVC, webm — в mp4, «без звука» — без звука.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f" | head -n 1)
  ac=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f" | head -n 1)
  base="${f%.*}"
  ext="${f##*.}"
  target="$f"
  how=""
  case "$vc" in
    ""|h264|hevc|av1|prores|mjpeg|png) ;;
    *) how=hevc ;;
  esac
  if [ -z "$how" ] && [ -n "$vc" ]; then
    if [ -n "$NOAUDIO" ] && [ -n "$ac" ]; then how=copy; fi
    if [ "$ext" != mp4 ] && [ "$ext" != mov ]; then how=copy; fi
  fi
  if [ -n "$how" ]; then
    target="$base.mp4"
    tmp="$base.tvorez-tmp.mp4"
    if [ "$how" = hevc ]; then
      echo "[convert] $vc -> HEVC: $(basename "$f")"
      set -- -c:v hevc_videotoolbox -q:v 65 -tag:v hvc1
    else
      set -- -c:v copy
    fi
    if [ -n "$NOAUDIO" ]; then
      set -- "$@" -an
    elif [ "$how" = hevc ] || [ "$ac" = opus ] || [ "$ac" = vorbis ]; then
      set -- "$@" -c:a aac -b:a 256k
    else
      set -- "$@" -c:a copy
    fi
    if ffmpeg -hide_banner -loglevel error -nostdin -y -i "$f" -map 0:v:0 -map "0:a?" "$@" "$tmp"; then
      [ "$f" != "$target" ] && rm -f "$f"
      mv -f "$tmp" "$target"
    else
      rm -f "$tmp"
      target="$f"
    fi
  fi
  printf '%s\t%s\n' "$f" "$target" >> "$READY"
done < "$LIST"
echo "__DONE__ $rc"
]==]

local UPDATE_SH = [==[
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
echo "brew upgrade yt-dlp"
"$BREW" upgrade yt-dlp
rc=$?
echo "yt-dlp $("$YTDLP" --version)"
echo "__DONE__ $rc"
]==]

local job

local function startJob(kind, body, args, files, env)
  local dir = trim(run("mktemp -d -t tvorez"))
  for name, content in pairs(files or {}) do
    writeFile(dir .. "/" .. name, content)
  end
  writeFile(dir .. "/run.sh", body)
  local vars = { JOB = dir, YTDLP = YTDLP or "", BREW = BREW or "" }
  for k, v in pairs(env or {}) do vars[k] = v end
  local assigns = {}
  for k, v in pairs(vars) do assigns[#assigns + 1] = k .. "=" .. sh(v) end
  local quoted = {}
  for i, a in ipairs(args or {}) do quoted[i] = sh(a) end
  -- В фон уходит одна команда со своими перенаправлениями, поэтому popen
  -- сразу получает PID и не ждёт окончания загрузки.
  local cmd = ("%s nohup /bin/sh %s %s > %s 2>&1 < /dev/null & echo $!")
    :format(table.concat(assigns, " "), sh(dir .. "/run.sh"), table.concat(quoted, " "), sh(dir .. "/log.txt"))
  job = { kind = kind, dir = dir, pid = run(cmd):match("%d+"), ticks = 0 }
  return job
end

local function clock(secs)
  secs = math.floor(secs + 0.5)
  local h, m = math.floor(secs / 3600), math.floor(secs % 3600 / 60)
  if h > 0 then return ("%d:%02d:%02d"):format(h, m, secs % 60) end
  return ("%d:%02d"):format(m, secs % 60)
end

local function clockName(secs)
  return ("%d.%02d"):format(math.floor(secs / 60), math.floor(secs % 60))
end

-- opts: urls, dir, mode, quality, browser, playlist, clip = {from, to}
local function startDownload(opts)
  local name = "%(title).120B [%(id)s]"
  if opts.clip then
    name = name .. " " .. clockName(opts.clip.from) .. "-" .. (opts.clip.to and clockName(opts.clip.to) or "end")
  end
  local args = {
    "--newline", "--progress", "--progress-delta", "1", "--no-mtime",
    "--ignore-errors", "--no-warnings",
    opts.playlist and "--yes-playlist" or "--no-playlist",
    "--ffmpeg-location", FFMPEG,
    "-P", opts.dir,
    "-o", name .. ".%(ext)s",
    "--progress-template",
    "download:[prog]%(progress._percent_str)s\t%(progress._speed_str)s\t%(progress._eta_str)s\t%(info.title)s",
  }
  for _, a in ipairs(formatArgs(opts.mode, opts.quality)) do args[#args + 1] = a end
  if opts.clip then
    args[#args + 1] = "--download-sections"
    args[#args + 1] = ("*%s-%s"):format(opts.clip.from, opts.clip.to or "inf")
    -- Без перекодирования звук режется по ближайшему кластеру, а не по секунде.
    -- Для видео это слишком долго, там хватает точности по ключевым кадрам.
    if opts.mode == MODE_AUDIO then args[#args + 1] = "--force-keyframes-at-cuts" end
  end
  if opts.browser then
    args[#args + 1] = "--cookies-from-browser"
    args[#args + 1] = opts.browser
  end
  return startJob("download", DOWNLOAD_SH, args,
    { ["urls.txt"] = table.concat(opts.urls, "\n") .. "\n" },
    { META = META_TEMPLATE, NOAUDIO = opts.mode == MODE_VIDEO and "1" or "" })
end

local function finishJob()
  if job then os.execute("rm -rf " .. sh(job.dir)) end
  job = nil
end

local function stopJob()
  if job and job.pid then
    os.execute(("kill_tree() { kids=$(pgrep -P $1); kill $1 2>/dev/null; for c in $kids; do kill_tree $c; done; }; kill_tree %s")
      :format(job.pid))
  end
  finishJob()
end

local function parseProgress(line)
  local pct, speed, eta, title = (line or ""):match("^(.-)\t(.-)\t(.-)\t(.*)$")
  if not pct then return nil end
  local function clean(v)
    v = trim(v)
    if v == "" or v:match("Unknown") or v:match("^NA") then return nil end
    return v
  end
  return {
    pct = tonumber(pct:match("([%d%.]+)%%")),
    speed = clean(speed),
    eta = clean(eta),
    title = clean(title),
  }
end

-- Состояние фоновой задачи: done, rc, progress, скачано файлов, журнал, итоговые файлы.
local function pollJob()
  local log = readFile(job.dir .. "/log.txt") or ""
  local st = { rc = tonumber(log:match("__DONE__ (%d+)")) }
  st.done = st.rc ~= nil
  st.downloaded = #splitLines(readFile(job.dir .. "/downloaded.txt"))
  local lines = {}
  for _, l in ipairs(splitLines(log)) do
    local p = l:match("^%[prog%](.*)$")
    if p then
      st.progress = parseProgress(p)
    elseif not l:match("^__DONE__") then
      lines[#lines + 1] = l
    end
  end
  st.lastLine = lines[#lines] or ""
  st.converting = not st.done and st.lastLine:match("^%[convert%]") ~= nil
  st.errors = 0
  local feed = {}
  for i = #lines, math.max(1, #lines - 300), -1 do
    feed[#feed + 1] = lines[i]
    if lines[i]:match("^ERROR") then st.errors = st.errors + 1 end
  end
  st.log = table.concat(feed, "\n")

  if st.done and job.kind == "download" then
    local meta = {}
    for _, l in ipairs(splitLines(readFile(job.dir .. "/meta.txt"))) do
      local path, title, dur, height, site = l:match("^(.-)\t(.-)\t(.-)\t(.-)\t(.*)$")
      if path then meta[path] = { title = title, dur = dur, height = height, site = site } end
    end
    st.files = {}
    for _, l in ipairs(splitLines(readFile(job.dir .. "/ready.txt"))) do
      local orig, final = l:match("^(.-)\t(.*)$")
      if orig then
        local m = meta[orig] or {}
        m.path = final
        st.files[#st.files + 1] = m
      end
    end
  end
  return st
end

-------------------------------------------------------------------------------
-- Импорт в Resolve
-------------------------------------------------------------------------------

local function currentProject()
  return resolve:GetProjectManager():GetCurrentProject()
end

local function findOrCreateBin(mediaPool, name)
  local root = mediaPool:GetRootFolder()
  if name == "" then return root end
  for _, folder in ipairs(root:GetSubFolderList() or {}) do
    if folder:GetName() == name then return folder end
  end
  return mediaPool:AddSubFolder(root, name)
end

local function importToResolve(paths, binName, toTimeline)
  local project = currentProject()
  local mediaPool = project:GetMediaPool()
  local bin = findOrCreateBin(mediaPool, binName)
  if bin then mediaPool:SetCurrentFolder(bin) end
  local items = {}
  for _, item in ipairs(mediaPool:ImportMedia(paths) or {}) do items[#items + 1] = item end
  if toTimeline and #items > 0 then
    if project:GetCurrentTimeline() then
      mediaPool:AppendToTimeline(items)
    else
      mediaPool:CreateTimelineFromClips(binName ~= "" and binName or "tvorez", items)
    end
  end
  return items
end

-------------------------------------------------------------------------------
-- Оформление: чёрный HUD, тонкие линии, красный акцент
-------------------------------------------------------------------------------

local C = {
  bg = "#060608", panel = "#0b0b0f", field = "#0d0d12",
  line = "#1d1d24", lineHi = "#35353e",
  text = "#e7e7ec", dim = "#8b8b96", faint = "#4a4a54",
  red = "#ff3b2f", redHi = "#ff5d52", redDim = "#4a1a16",
}

local function css(extra, s)
  if s == nil then extra, s = {}, extra end
  return (s:gsub("@(%w+)", function(k) return C[k] or extra[k] end))
end

local BASE_CSS = [[
QWidget { background-color: @bg; color: @text; font-family: Menlo; font-size: 11px; }
QLabel { background: transparent; }
QLineEdit, QTextEdit, QComboBox {
  background-color: @field; border: 1px solid @line; border-radius: 0px;
  padding: 5px 8px; selection-background-color: @red; selection-color: #000000;
}
QLineEdit:focus, QTextEdit:focus, QComboBox:focus { border-color: @dim; }
QLineEdit:disabled, QComboBox:disabled { color: @faint; border-color: #15151a; }
QLineEdit[readOnly="true"] { color: @dim; }
QComboBox::drop-down { border: none; width: 24px; }
QComboBox::down-arrow { image: url(@arrow); width: 10px; height: 6px; }
QComboBox QAbstractItemView {
  background-color: @panel; border: 1px solid @lineHi; outline: 0;
  selection-background-color: @red; selection-color: #000000;
}
QCheckBox { spacing: 8px; }
QCheckBox:disabled { color: @faint; }
QCheckBox::indicator { width: 11px; height: 11px; border: 1px solid @lineHi; background: @field; }
QCheckBox::indicator:hover { border-color: @text; }
QCheckBox::indicator:checked { background: @red; border-color: @red; image: url(@check); }
QPushButton {
  background: transparent; color: @text; border: 1px solid @lineHi;
  border-radius: 0px; padding: 6px 12px;
}
QPushButton:hover { border-color: @text; }
QPushButton:pressed { background: #141419; }
QPushButton:disabled { color: @faint; border-color: #18181d; }
QTreeWidget {
  background: @bg; alternate-background-color: #09090c;
  border: 1px solid @line; outline: 0;
}
QTreeWidget::item { padding: 3px 0px; }
QTreeWidget::item:selected { background: #2a0d0b; color: #ffffff; }
QHeaderView::section {
  background: @bg; color: @faint; border: none; border-bottom: 1px solid @line;
  padding: 4px 6px; font-size: 10px;
}
QScrollBar:vertical { background: transparent; width: 6px; margin: 0px; }
QScrollBar::handle:vertical { background: @lineHi; min-height: 24px; }
QScrollBar:horizontal { background: transparent; height: 6px; margin: 0px; }
QScrollBar::handle:horizontal { background: @lineHi; min-width: 24px; }
QScrollBar::add-line, QScrollBar::sub-line { width: 0px; height: 0px; }
QScrollBar::add-page, QScrollBar::sub-page { background: none; }
]]

local PRIMARY_CSS = css({}, [[
QPushButton { background: @red; color: #000000; border: 1px solid @red; padding: 8px 30px; font-weight: bold; }
QPushButton:hover { background: @redHi; border-color: @redHi; }
QPushButton:pressed { background: #d42a20; }
QPushButton:disabled { background: transparent; color: @redDim; border-color: @redDim; }
]])

local STOP_CSS = css({}, [[
QPushButton { color: @red; border-color: @redDim; padding: 8px 16px; }
QPushButton:hover { border-color: @red; }
QPushButton:disabled { color: @faint; border-color: #18181d; }
]])

local FOOT_CSS = css([[
QPushButton { padding: 8px 14px; }
QPushButton:hover { border-color: @text; }
QPushButton:disabled { color: @faint; border-color: #18181d; }
]])

local TAB_ON_CSS = css("QPushButton { border: none; border-bottom: 2px solid @red; color: @text; padding: 5px 2px; }")
local TAB_OFF_CSS = css({}, [[
QPushButton { border: none; border-bottom: 2px solid transparent; color: @faint; padding: 5px 2px; }
QPushButton:hover { color: @text; }
]])

local LINE_CSS = css("QLabel { background: @line; }")
local DIM_CSS = css("QLabel { color: @dim; }")
local FAINT_CSS = css("QLabel { color: @faint; }")

local function span(color, text)
  return ("<span style='color:%s'>%s</span>"):format(color, text)
end

local function readoutHtml(caption, value, unit, color)
  return ([[<div style="color:%s; font-size:9px;">%s</div>]]
    .. [[<div style="font-family:'DIN Alternate'; font-size:30px; color:%s;">%s]]
    .. [[<span style="font-size:13px; color:%s;">&nbsp;%s</span></div>]])
    :format(C.faint, caption, color or C.text, value, C.dim, unit or "")
end

local TICKS = 96

-- Шкала из штрихов: frac — доля заполнения, scan — позиция бегущего сегмента.
local function tickBarHtml(frac, color, scan)
  local cells = {}
  local filled = math.floor(TICKS * math.max(0, math.min(1, frac or 0)) + 0.5)
  for i = 1, TICKS do
    local c
    if scan then
      local d = (i - scan) % TICKS
      c = d < 10 and C.red or ((i % 10 == 0) and C.faint or C.line)
    elseif i <= filled then
      c = color or C.red
    else
      c = (i % 10 == 0) and C.faint or C.line
    end
    cells[i] = span(c, "|")
  end
  return "<span style='font-family:Menlo; font-size:12px;'>" .. table.concat(cells) .. "</span>"
end

local function statusHtml(text, color)
  return span(C.red, "&gt;&nbsp;") .. span(color or C.dim, text)
end

-------------------------------------------------------------------------------
-- Окно
-------------------------------------------------------------------------------

local function main()
  ensureAssets()

  local ui = fu.UIManager
  local disp = bmd.UIDispatcher(ui)
  local settings = loadSettings()
  local history = loadHistory()

  local function header(num, title, ...)
    return ui:HGroup{ Weight = 0, Spacing = 10,
      ui:Label{ Weight = 0, Text = span(C.red, num) .. span(C.dim, "&nbsp;/&nbsp;" .. title) },
      ui:VGroup{ Weight = 1,
        ui:VGap(0, 1),
        ui:Label{ Weight = 0, MinimumSize = { 10, 1 }, MaximumSize = { 16777215, 1 }, StyleSheet = LINE_CSS },
        ui:VGap(0, 1),
      },
      ...
    }
  end

  local function caption(text)
    return ui:Label{ Weight = 0, Text = text, MinimumSize = { 86, 0 }, StyleSheet = DIM_CSS }
  end

  local win = disp:AddWindow({
    ID = "TvorezWin",
    WindowTitle = "TVOREZ — загрузчик медиа",
    Geometry = { 240, 36, 780, 860 },
    WindowFlags = WINDOW_FLAGS,
    StyleSheet = css({ arrow = ASSETS_DIR .. "/arrow.png", check = ASSETS_DIR .. "/check.png" }, BASE_CSS),

    ui:VGroup{ Spacing = 7,
      ui:Label{ ID = "Banner", Weight = 0, MinimumSize = { 1, 124 }, Alignment = { AlignHCenter = true },
        Text = ("<img src='%s/banner.png' width='740' height='124'>"):format(ASSETS_DIR) },

      header("01", "ИСТОЧНИК",
        ui:Button{ ID = "Paste", Weight = 0, Text = "ВСТАВИТЬ ИЗ БУФЕРА" },
        ui:Button{ ID = "Clear", Weight = 0, Text = "ОЧИСТИТЬ" }),
      ui:TextEdit{ ID = "Urls", Weight = 0, MinimumSize = { 200, 64 }, MaximumSize = { 16777215, 84 },
        PlaceholderText = "Ссылки — по одной на строку: YouTube, Instagram, TikTok, VK, Vimeo…" },

      header("02", "ФОРМАТ"),
      ui:HGroup{ Weight = 0,
        ui:ComboBox{ ID = "Mode", Weight = 1 },
        ui:ComboBox{ ID = "Quality", Weight = 1 },
      },
      ui:HGroup{ Weight = 0, Spacing = 10,
        ui:CheckBox{ ID = "Clip", Weight = 0, Text = "ТОЛЬКО ОТРЕЗОК" },
        ui:Label{ Weight = 0, Text = "С", StyleSheet = DIM_CSS },
        ui:LineEdit{ ID = "ClipFrom", Weight = 1, PlaceholderText = "0:00" },
        ui:Label{ Weight = 0, Text = "ПО", StyleSheet = DIM_CSS },
        ui:LineEdit{ ID = "ClipTo", Weight = 1, PlaceholderText = "конец" },
        ui:Label{ Weight = 2, Text = "" },
        ui:CheckBox{ ID = "Playlist", Weight = 0, Text = "ВЕСЬ ПЛЕЙЛИСТ" },
      },

      header("03", "НАЗНАЧЕНИЕ"),
      ui:HGroup{ Weight = 0,
        caption("ПАПКА"),
        ui:LineEdit{ ID = "Dir", Weight = 1, ReadOnly = true },
        ui:Button{ ID = "Browse", Weight = 0, Text = "ВЫБРАТЬ" },
        ui:Button{ ID = "Reveal", Weight = 0, Text = "FINDER" },
      },
      ui:HGroup{ Weight = 0,
        caption(""),
        ui:CheckBox{ ID = "PerProject", Weight = 0, Text = "ПОДПАПКА ПРОЕКТА" },
        ui:Label{ ID = "Target", Weight = 1, MinimumSize = { 1, 1 }, StyleSheet = FAINT_CSS, Alignment = { AlignRight = true, AlignVCenter = true } },
      },
      ui:HGroup{ Weight = 0,
        caption("MEDIA POOL"),
        ui:LineEdit{ ID = "Bin", Weight = 1, PlaceholderText = "пусто — в корень Master" },
        ui:CheckBox{ ID = "Timeline", Weight = 0, Text = "СРАЗУ НА ТАЙМЛАЙН" },
      },
      ui:HGroup{ Weight = 0,
        caption("БРАУЗЕР"),
        ui:ComboBox{ ID = "Cookies", Weight = 1 },
        ui:Label{ Weight = 0, Text = "для Instagram и закрытых видео", StyleSheet = FAINT_CSS },
      },

      header("04", "ТЕЛЕМЕТРИЯ"),
      ui:HGroup{ Weight = 0,
        ui:Label{ ID = "RoPct", Weight = 1 },
        ui:Label{ ID = "RoSpeed", Weight = 1 },
        ui:Label{ ID = "RoEta", Weight = 1 },
        ui:Label{ ID = "RoFiles", Weight = 1 },
      },
      ui:Label{ ID = "Bar", Weight = 0, MinimumSize = { 1, 18 } },
      ui:Label{ ID = "Status", Weight = 0, WordWrap = true, MinimumSize = { 1, 16 } },

      ui:HGroup{ Weight = 0, Spacing = 18,
        ui:Button{ ID = "TabHistory", Weight = 0, Text = "ИСТОРИЯ" },
        ui:Button{ ID = "TabLog", Weight = 0, Text = "ЖУРНАЛ" },
        ui:HGap(0, 1),
        ui:Label{ ID = "Hint", Weight = 0, Text = "двойной клик — показать файл в Finder", StyleSheet = FAINT_CSS },
      },
      ui:Tree{ ID = "History", Weight = 1, MinimumSize = { 200, 110 } },
      ui:TextEdit{ ID = "Log", Weight = 1, ReadOnly = true, MinimumSize = { 200, 110 } },

      ui:Label{ Weight = 0, MinimumSize = { 10, 1 }, MaximumSize = { 16777215, 1 }, StyleSheet = LINE_CSS },
      ui:HGroup{ Weight = 0,
        ui:Button{ ID = "UpdateTool", Weight = 0, Text = "ОБНОВИТЬ YT-DLP", StyleSheet = FOOT_CSS },
        ui:Label{ ID = "ToolInfo", Weight = 1, MinimumSize = { 1, 1 }, StyleSheet = FAINT_CSS },
        ui:Button{ ID = "Cancel", Weight = 0, Text = "СТОП", Enabled = false, StyleSheet = STOP_CSS },
        ui:Button{ ID = "Go", Weight = 0, Text = "СКАЧАТЬ  ▸", StyleSheet = PRIMARY_CSS },
      },
    },
  })

  local itm = win:GetItems()

  ---------------------------------------------------------------------------
  -- Начальное состояние
  ---------------------------------------------------------------------------

  for _, m in ipairs(MODES) do itm.Mode:AddItem(m) end
  for _, q in ipairs(QUALITIES) do itm.Quality:AddItem(q.label) end
  for _, b in ipairs(BROWSERS) do itm.Cookies:AddItem(b) end

  itm.Mode.CurrentIndex = tonumber(settings.mode) or 0
  itm.Quality.CurrentIndex = tonumber(settings.quality) or 0
  itm.Cookies.CurrentIndex = tonumber(settings.cookies) or 0
  itm.Dir.Text = settings.dir
  itm.PerProject.Checked = settings.perProject == "1"
  itm.Bin.Text = settings.bin
  itm.Timeline.Checked = settings.timeline == "1"
  itm.Playlist.Checked = settings.playlist == "1"

  itm.History:SetHeaderLabels({ "#", "НАЗВАНИЕ", "ДЛИНА", "ФОРМАТ", "ИСТОЧНИК", "КОГДА" })
  for col, width in ipairs({ 44, 318, 64, 104, 96, 90 }) do
    itm.History.ColumnWidth[col - 1] = width
  end
  itm.History.AlternatingRowColors = true
  itm.History.RootIsDecorated = false

  local function refreshFormat()
    itm.Quality.Enabled = itm.Mode.CurrentIndex + 1 ~= MODE_AUDIO
    itm.ClipFrom.Enabled = itm.Clip.Checked
    itm.ClipTo.Enabled = itm.Clip.Checked
  end

  local function targetDir()
    local dir = itm.Dir.Text
    if itm.PerProject.Checked then
      local project = currentProject()
      local name = project and project:GetName() or "Без проекта"
      dir = dir .. "/" .. name:gsub("[/:]", "-")
    end
    return dir
  end

  local function refreshTarget()
    itm.Target.Text = "→ " .. tail(shortPath(targetDir()), 48)
  end

  local function refreshToolInfo()
    local parts = {
      YTDLP and ("YT-DLP " .. (ytdlpVersion() or "OK")) or span(C.red, "YT-DLP НЕ НАЙДЕН"),
      FFMPEG and "FFMPEG OK" or span(C.red, "FFMPEG НЕ НАЙДЕН"),
      "TVOREZ " .. VERSION,
    }
    itm.ToolInfo.Text = "<span>&nbsp;&nbsp;" .. table.concat(parts, "&nbsp;&nbsp;//&nbsp;&nbsp;") .. "</span>"
  end

  local function setReadouts(pct, speed, eta, files, pctColor)
    itm.RoPct.Text = readoutHtml("ЗАГРУЗКА", pct or "---", "%", pctColor)
    itm.RoSpeed.Text = readoutHtml("СКОРОСТЬ", speed or "---", "")
    itm.RoEta.Text = readoutHtml("ОСТАЛОСЬ", eta or "--:--", "")
    itm.RoFiles.Text = readoutHtml("ФАЙЛЫ", files or "00", "")
  end

  local function setStatus(text, color)
    itm.Status.Text = statusHtml(text, color)
  end

  local function setTab(name)
    local isLog = name == "log"
    itm.History.Hidden = isLog
    itm.Hint.Hidden = isLog
    itm.Log.Hidden = not isLog
    itm.TabHistory.StyleSheet = isLog and TAB_OFF_CSS or TAB_ON_CSS
    itm.TabLog.StyleSheet = isLog and TAB_ON_CSS or TAB_OFF_CSS
  end

  local historyById = {}

  local function renderHistory()
    itm.History:Clear()
    historyById = {}
    for i = #history, math.max(1, #history - HISTORY_LIMIT + 1), -1 do
      local e = history[i]
      historyById[e.id] = e
      local row = itm.History:NewItem()
      row.Text[0] = e.id
      row.Text[1] = e.title
      row.Text[2] = e.dur
      row.Text[3] = e.fmt
      row.Text[4] = e.site
      row.Text[5] = e.when
      itm.History:AddTopLevelItem(row)
    end
  end

  local function addToHistory(files, clip)
    local lastId = tonumber(history[#history] and history[#history].id) or 0
    for _, f in ipairs(files) do
      lastId = lastId + 1
      local ext = (f.path:match("%.(%w+)$") or ""):upper()
      local height = f.height and f.height ~= "" and (f.height .. "  ·  ") or ""
      local dur = f.dur or "—"
      if dur:match("^%d+$") then dur = clock(tonumber(dur)) end
      if clip then
        dur = clip.to and clock(clip.to - clip.from) or ("с " .. clock(clip.from))
      end
      history[#history + 1] = {
        id = ("%03d"):format(lastId),
        when = os.date("%d.%m  %H:%M"),
        title = oneLine(f.title or f.path:match("([^/]+)%.%w+$")),
        dur = dur,
        fmt = height .. ext,
        site = (f.site or ""):upper(),
        path = f.path,
      }
    end
    saveHistory(history)
    renderHistory()
  end

  local function rememberSettings()
    settings.dir = itm.Dir.Text
    settings.perProject = itm.PerProject.Checked and "1" or "0"
    settings.mode = tostring(itm.Mode.CurrentIndex)
    settings.quality = tostring(itm.Quality.CurrentIndex)
    settings.bin = itm.Bin.Text
    settings.timeline = itm.Timeline.Checked and "1" or "0"
    settings.cookies = tostring(itm.Cookies.CurrentIndex)
    settings.playlist = itm.Playlist.Checked and "1" or "0"
    saveSettings(settings)
  end

  local function setBusy(busy)
    itm.Go.Enabled = not busy
    itm.UpdateTool.Enabled = not busy
    itm.Cancel.Enabled = busy
  end

  local function clipboardUrls()
    local urls = {}
    for u in run("pbpaste 2>/dev/null"):gmatch("https?://[^%s\"'<>]+") do urls[#urls + 1] = u end
    return urls
  end

  local function addUrls(urls)
    local text = trim(itm.Urls.PlainText)
    for _, u in ipairs(urls) do
      if not text:find(u, 1, true) then
        text = text == "" and u or (text .. "\n" .. u)
      end
    end
    itm.Urls.PlainText = text
  end

  local function chooseDir(start)
    local ok, path = pcall(function() return fu:RequestDir(start .. "/") end)
    if not ok then
      path = trim(run([[osascript -e 'POSIX path of (choose folder with prompt "Рабочая папка TVOREZ")' 2>/dev/null]]))
    end
    if path and path ~= "" then
      return (path:gsub("/+$", ""))
    end
  end

  -- «1:05», «65», «1:02:03» → секунды; пусто → nil; мусор → false
  local function parseTime(s)
    s = trim(s)
    if s == "" then return nil end
    local secs = 0
    for part in s:gmatch("[^:]+") do
      local n = tonumber(part)
      if not n then return false end
      secs = secs * 60 + n
    end
    return secs
  end

  local timer = ui:Timer{ ID = "Poll", Interval = 500 }

  refreshFormat()
  refreshTarget()
  refreshToolInfo()
  setReadouts()
  itm.Bar.Text = tickBarHtml(0)
  setTab("history")
  renderHistory()

  if not YTDLP or not FFMPEG then
    itm.Go.Enabled = false
    setStatus("Не найдены yt-dlp / ffmpeg. В Терминале: brew install yt-dlp ffmpeg", C.red)
  else
    local found = clipboardUrls()
    if #found > 0 then
      addUrls(found)
      setStatus("Ссылка из буфера уже вставлена. Жми «Скачать».", C.text)
    else
      setStatus("Система готова. Вставь ссылку и жми «Скачать».")
    end
  end

  ---------------------------------------------------------------------------
  -- События
  ---------------------------------------------------------------------------

  function win.On.Mode.CurrentIndexChanged(ev) refreshFormat() end
  function win.On.Clip.Clicked(ev) refreshFormat() end
  function win.On.PerProject.Clicked(ev) refreshTarget() end
  function win.On.TabHistory.Clicked(ev) setTab("history") end
  function win.On.TabLog.Clicked(ev) setTab("log") end

  function win.On.Paste.Clicked(ev)
    local found = clipboardUrls()
    if #found == 0 then
      setStatus("В буфере обмена нет ссылок.", C.text)
    else
      addUrls(found)
      setStatus(("Добавлено ссылок из буфера: %d."):format(#found), C.text)
    end
  end

  function win.On.Clear.Clicked(ev)
    itm.Urls.PlainText = ""
  end

  function win.On.Browse.Clicked(ev)
    local dir = chooseDir(itm.Dir.Text)
    if dir then
      itm.Dir.Text = dir
      refreshTarget()
      rememberSettings()
    end
  end

  function win.On.Reveal.Clicked(ev)
    local dir = targetDir()
    mkdir(dir)
    os.execute("open " .. sh(dir))
  end

  function win.On.History.ItemClicked(ev)
    local e = historyById[ev.item.Text[0]]
    if e then setStatus(shortPath(e.path)) end
  end

  function win.On.History.ItemDoubleClicked(ev)
    local e = historyById[ev.item.Text[0]]
    if not e then return end
    if fileExists(e.path) then
      os.execute("open -R " .. sh(e.path))
    else
      setStatus("Файл перемещён или удалён: " .. shortPath(e.path), C.red)
    end
  end

  function win.On.Go.Clicked(ev)
    local urls = {}
    for _, l in ipairs(splitLines(itm.Urls.PlainText)) do
      local u = trim(l)
      if u:match("^https?://") then urls[#urls + 1] = u end
    end
    if #urls == 0 then
      setStatus("Не вижу ссылок: каждая должна начинаться с http:// или https://", C.red)
      return
    end

    local clip
    if itm.Clip.Checked then
      local from, to = parseTime(itm.ClipFrom.Text), parseTime(itm.ClipTo.Text)
      if from == false or to == false then
        setStatus("Время отрезка пишется так: 1:05 или 65 (секунды).", C.red)
        return
      end
      from = from or 0
      if to and to <= from then
        setStatus("Конец отрезка должен быть позже начала.", C.red)
        return
      end
      clip = { from = from, to = to }
    end

    rememberSettings()
    local dir = targetDir()
    mkdir(dir)
    local cookies = itm.Cookies.CurrentIndex

    startDownload({
      urls = urls,
      dir = dir,
      mode = itm.Mode.CurrentIndex + 1,
      quality = itm.Quality.CurrentIndex + 1,
      browser = cookies > 0 and BROWSERS[cookies + 1] or nil,
      playlist = itm.Playlist.Checked,
      clip = clip,
    })
    job.total = not itm.Playlist.Checked and #urls or nil
    job.clip = clip
    itm.Log.PlainText = ""
    setReadouts("000", nil, nil, job.total and ("00/%02d"):format(job.total) or "00")
    itm.Bar.Text = tickBarHtml(0)
    setStatus(("Старт загрузки: %d шт. → %s"):format(#urls, shortPath(dir)), C.text)
    setBusy(true)
    timer:Start()
  end

  function win.On.UpdateTool.Clicked(ev)
    if not BREW then
      setStatus("Homebrew не найден — обнови yt-dlp тем же способом, каким ставил.", C.red)
      return
    end
    startJob("update", UPDATE_SH)
    itm.Log.PlainText = ""
    setTab("log")
    setReadouts()
    setStatus("Обновляю yt-dlp через Homebrew…", C.text)
    setBusy(true)
    timer:Start()
  end

  function win.On.Cancel.Clicked(ev)
    timer:Stop()
    stopJob()
    setBusy(false)
    setReadouts()
    itm.Bar.Text = tickBarHtml(0)
    setStatus("Остановлено. Недокачанные куски (.part) можно удалить из рабочей папки.", C.red)
  end

  function disp.On.Timeout(ev)
    if ev.who ~= "Poll" or not job then return end
    job.ticks = job.ticks + 1
    local st = pollJob()
    if st.log ~= itm.Log.PlainText then
      itm.Log.PlainText = st.log
    end

    if not st.done then
      if job.kind == "update" then
        itm.Bar.Text = tickBarHtml(0, nil, job.ticks * 3)
        return
      end
      local p = st.progress or {}
      local done = st.downloaded
      local files = job.total and ("%02d/%02d"):format(math.min(done, job.total), job.total) or ("%02d"):format(done)
      if st.converting then
        setReadouts("---", nil, nil, files)
        itm.Bar.Text = tickBarHtml(0, nil, job.ticks * 3)
        setStatus("Перекодирую в HEVC, чтобы Resolve открыл файл…", C.text)
      elseif p.pct then
        setReadouts(("%03d"):format(math.floor(p.pct)), p.speed, p.eta, files, C.red)
        itm.Bar.Text = tickBarHtml(p.pct / 100)
        setStatus(p.title and ("Скачиваю: " .. p.title) or "Скачиваю…", C.text)
      else
        setReadouts("---", p.speed, p.eta, files)
        itm.Bar.Text = tickBarHtml(0, nil, job.ticks * 3)
        setStatus(p.title and ("Скачиваю: " .. p.title) or "Получаю информацию о видео…", C.text)
      end
      return
    end

    timer:Stop()
    local finished = job
    finishJob()
    setBusy(false)

    if finished.kind == "update" then
      refreshToolInfo()
      itm.Bar.Text = tickBarHtml(st.rc == 0 and 1 or 0)
      if st.rc == 0 then
        setStatus("yt-dlp обновлён.", C.text)
      else
        setStatus("Не получилось обновить — подробности в журнале.", C.red)
      end
      return
    end

    local files = st.files
    if #files == 0 then
      setReadouts("000", nil, nil, "00")
      itm.Bar.Text = tickBarHtml(0)
      setTab("log")
      setStatus("Ничего не скачалось — причина в журнале. Помогает «Обновить yt-dlp» или «Браузер».", C.red)
      return
    end

    local paths = {}
    for i, f in ipairs(files) do paths[i] = f.path end
    local binName = trim(itm.Bin.Text)
    local items = importToResolve(paths, binName, itm.Timeline.Checked)
    addToHistory(files, finished.clip)
    setTab("history")

    local total = finished.total or #files
    setReadouts("100", nil, "00:00", ("%02d/%02d"):format(#files, total), C.red)
    itm.Bar.Text = tickBarHtml(1)
    local where = binName ~= "" and ("«" .. binName .. "»") or "Media Pool"
    local text = ("Готово: %d в %s."):format(#items, where)
    local failed = st.errors > 0 or (finished.total and #files < finished.total)
    if failed then
      text = text .. " Часть ссылок не скачалась — см. журнал."
    else
      itm.Urls.PlainText = ""
    end
    if #items < #files then
      text = text .. (" Resolve не принял файлов: %d."):format(#files - #items)
    end
    setStatus(text, (failed or #items < #files) and C.red or C.text)
  end

  function win.On.TvorezWin.Close(ev)
    if job then
      timer:Stop()
      stopJob()
    end
    disp:ExitLoop()
  end

  win:Show()
  disp:RunLoop()
  win:Hide()
end

-------------------------------------------------------------------------------
-- Графика интерфейса (PNG в base64)
-------------------------------------------------------------------------------

--@@ASSETS@@

-- Для проверки из терминала: INET_IMPORT_NO_UI = true; local api = chunk()
if INET_IMPORT_NO_UI then
  return {
    startDownload = startDownload, pollJob = pollJob, stopJob = stopJob, finishJob = finishJob,
    importToResolve = importToResolve, YTDLP = YTDLP, FFMPEG = FFMPEG,
  }
end

main()
