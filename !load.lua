local encoding = require "encoding"
encoding.default = 'CP1251'
u8 = encoding.UTF8

local active = false
local afkEnabled = false
local afkActive = false
local lastSpamTime = 0
local needToggle = false
local spamThread = nil
local commandCount = 0
local startTime = 0
local attemptsCount = 0
local missedCount = 0
local waitingForKey = false
local settingPosition = false
local antifloodPause = false
local protectionActive = false
local lastNoQuestionsTime = 0
local escWasDown = false
local escConsumed = false

-- Перехват WM_KEYDOWN через ffi для блокировки ESC от игры
local escHookActive = false

local function escPressed()
    if escConsumed then
        escConsumed = false
        return true
    end
    return false
end
local notifyMinimizedEnabled = true

-- ===================== WINDOW CONFIG (окно ловли) =====================
-- Жестко закодированные параметры окна ловли
local winCfg = {
    w               = 250,
    h               = 68,
    cornerRadius    = 12.0,
    borderThickness = 1.5,
    dashLen         = 10.0,
    gapLen          = 8.0,
    dashSpeed       = 25.0,
    showPing        = true,
    showTimer       = true,
    showAttempts    = true,
    showMissed      = false,
    showCustom      = false,
    title           = u8"Ловля..",
    customText      = "",
    titleX    = 95, titleY    = 12,
    pingX     = 18, pingY     = 12,
    timerX    = 18, timerY    = 38,
    attemptsX = 75, attemptsY = 38,
    missedX   = 18, missedY   = 56,
    customX   = 96, customY   = 56,
}
-- ===================================================================


local hasSubscription = false

local ffi = require 'ffi'

ffi.cdef[[
    int MessageBoxA(void* hWnd, const char* text, const char* caption, unsigned int type);
    void* GetForegroundWindow(void);
    void* FindWindowA(const char* lpClassName, const char* lpWindowName);
    bool PostMessageA(void* hWnd, unsigned int Msg, uintptr_t wParam, intptr_t lParam);
    short GetAsyncKeyState(int vKey);
]]

-- ===================== THEME SYSTEM =====================
local theme = {
    color=nil,
    R=0.6,  G=0.6,  B=0.6,
    mR=0.45,mG=0.45,mB=0.45,
    bgR=0.06,bgG=0.06,bgB=0.06,
    pgR=0.2, pgG=1.0, pgB=0.2,
    pmR=1.0, pmG=0.85,pmB=0.1,
    pbR=1.0, pbG=0.2, pbB=0.2,
    toR=0.0, toG=0.8, toB=0.0,
    twR=1.0, twG=0.8, twB=0.0,
    tcR=1.0, tcG=0.0, tcB=0.0,
    aoR=0.2, aoG=1.0, aoB=0.2,
    amR=1.0, amG=0.85,amB=0.1,
    abR=1.0, abG=0.2, abB=0.2,
}

local function luminance(r,g,b) return 0.299*r+0.587*g+0.114*b end
local function lerpC(r1,g1,b1,r2,g2,b2,t) return r1+(r2-r1)*t,g1+(g2-g1)*t,b1+(b2-b1)*t end
local function saturate(r,g,b,s) local l=luminance(r,g,b) return l+(r-l)*s,l+(g-l)*s,l+(b-l)*s end
local function clamp01(v) return math.max(0,math.min(1,v)) end

local function applyThemeColor(hex)
    if not hex then
        theme.color=nil; theme.R,theme.G,theme.B=0.6,0.6,0.6
        theme.mR,theme.mG,theme.mB=0.45,0.45,0.45
        theme.bgR,theme.bgG,theme.bgB=0.06,0.06,0.06
        theme.pgR,theme.pgG,theme.pgB=0.2,1.0,0.2
        theme.pmR,theme.pmG,theme.pmB=1.0,0.85,0.1
        theme.pbR,theme.pbG,theme.pbB=1.0,0.2,0.2
        theme.toR,theme.toG,theme.toB=0.0,0.8,0.0
        theme.twR,theme.twG,theme.twB=1.0,0.8,0.0
        theme.tcR,theme.tcG,theme.tcB=1.0,0.0,0.0
        theme.aoR,theme.aoG,theme.aoB=0.2,1.0,0.2
        theme.amR,theme.amG,theme.amB=1.0,0.85,0.1
        theme.abR,theme.abG,theme.abB=1.0,0.2,0.2
        return
    end
    hex=hex:gsub("^#","")
    local ri=tonumber(hex:sub(1,2),16)
    local gi=tonumber(hex:sub(3,4),16)
    local bi=tonumber(hex:sub(5,6),16)
    if not(ri and gi and bi) then return end
    theme.color=hex
    local r,g,b=ri/255.0,gi/255.0,bi/255.0
    local ar,ag,ab=saturate(r,g,b,2.2)
    local lum=luminance(ar,ag,ab)
    if lum<0.55 then local boost=0.55/math.max(lum,0.01); ar,ag,ab=ar*boost,ag*boost,ab*boost end
    ar,ag,ab=clamp01(ar),clamp01(ag),clamp01(ab)
    theme.R,theme.G,theme.B=ar,ag,ab
    local mr,mg,mb=lerpC(ar,ag,ab,0.55,0.55,0.55,0.45)
    theme.mR,theme.mG,theme.mB=clamp01(mr),clamp01(mg),clamp01(mb)
    local bgr,bgg,bgb=lerpC(0.04,0.04,0.04,ar,ag,ab,0.09)
    theme.bgR,theme.bgG,theme.bgB=clamp01(bgr),clamp01(bgg),clamp01(bgb)
    local isRed=(ar==math.max(ar,ag,ab) and ar>ag+0.15 and ar>ab+0.15)
    local isBlue=(ab==math.max(ar,ag,ab) and ab>ar+0.15 and ab>ag+0.15)
    local isPurple=(ar>0.4 and ab>0.4 and ag<0.4)
    local isCyan=(ag>0.4 and ab>0.4 and ar<0.4)
    local isYellow=(ar>0.6 and ag>0.6 and ab<0.3)
    local isGreen=(ag==math.max(ar,ag,ab) and ag>ar+0.15 and ag>ab+0.15)
    if isRed then
        theme.pgR,theme.pgG,theme.pgB=1.0,0.6,0.1
        theme.pmR,theme.pmG,theme.pmB=1.0,0.9,0.1
        theme.pbR,theme.pbG,theme.pbB=ar,ag*0.3,ab*0.3
        theme.toR,theme.toG,theme.toB=1.0,0.55,0.1
        theme.twR,theme.twG,theme.twB=1.0,0.85,0.1
        theme.tcR,theme.tcG,theme.tcB=ar,ag*0.2,ab*0.2
        theme.aoR,theme.aoG,theme.aoB=1.0,0.6,0.1
        theme.amR,theme.amG,theme.amB=1.0,0.9,0.1
        theme.abR,theme.abG,theme.abB=ar,ag*0.2,ab*0.2
    elseif isBlue then
        theme.pgR,theme.pgG,theme.pgB=0.1,0.85,1.0
        theme.pmR,theme.pmG,theme.pmB=0.7,0.4,1.0
        theme.pbR,theme.pbG,theme.pbB=1.0,0.25,0.25
        theme.toR,theme.toG,theme.toB=0.1,0.85,1.0
        theme.twR,theme.twG,theme.twB=0.7,0.4,1.0
        theme.tcR,theme.tcG,theme.tcB=1.0,0.25,0.25
        theme.aoR,theme.aoG,theme.aoB=0.1,0.85,1.0
        theme.amR,theme.amG,theme.amB=0.7,0.4,1.0
        theme.abR,theme.abG,theme.abB=1.0,0.25,0.25
    elseif isPurple then
        theme.pgR,theme.pgG,theme.pgB=0.75,0.5,1.0
        theme.pmR,theme.pmG,theme.pmB=1.0,0.4,0.8
        theme.pbR,theme.pbG,theme.pbB=1.0,0.2,0.3
        theme.toR,theme.toG,theme.toB=0.75,0.5,1.0
        theme.twR,theme.twG,theme.twB=1.0,0.4,0.8
        theme.tcR,theme.tcG,theme.tcB=1.0,0.2,0.3
        theme.aoR,theme.aoG,theme.aoB=0.75,0.5,1.0
        theme.amR,theme.amG,theme.amB=1.0,0.4,0.8
        theme.abR,theme.abG,theme.abB=1.0,0.2,0.3
    elseif isCyan then
        theme.pgR,theme.pgG,theme.pgB=0.1,1.0,0.85
        theme.pmR,theme.pmG,theme.pmB=0.1,0.9,0.4
        theme.pbR,theme.pbG,theme.pbB=1.0,0.45,0.1
        theme.toR,theme.toG,theme.toB=0.1,1.0,0.85
        theme.twR,theme.twG,theme.twB=0.1,0.9,0.4
        theme.tcR,theme.tcG,theme.tcB=1.0,0.45,0.1
        theme.aoR,theme.aoG,theme.aoB=0.1,1.0,0.85
        theme.amR,theme.amG,theme.amB=0.1,0.9,0.4
        theme.abR,theme.abG,theme.abB=1.0,0.45,0.1
    elseif isYellow or isGreen then
        theme.pgR,theme.pgG,theme.pgB=ar,ag,ab
        theme.pmR,theme.pmG,theme.pmB=1.0,0.6,0.1
        theme.pbR,theme.pbG,theme.pbB=1.0,0.2,0.2
        theme.toR,theme.toG,theme.toB=ar,ag,ab
        theme.twR,theme.twG,theme.twB=1.0,0.6,0.1
        theme.tcR,theme.tcG,theme.tcB=1.0,0.2,0.2
        theme.aoR,theme.aoG,theme.aoB=ar,ag,ab
        theme.amR,theme.amG,theme.amB=1.0,0.6,0.1
        theme.abR,theme.abG,theme.abB=1.0,0.2,0.2
    else
        theme.pgR,theme.pgG,theme.pgB=ar,ag,ab
        theme.pmR,theme.pmG,theme.pmB=clamp01(ar*0.8+0.4),clamp01(ag*0.8+0.4),clamp01(ab*0.4)
        theme.pbR,theme.pbG,theme.pbB=1.0,0.25,0.25
        theme.toR,theme.toG,theme.toB=ar,ag,ab
        theme.twR,theme.twG,theme.twB=clamp01(ar*0.8+0.4),clamp01(ag*0.8+0.4),clamp01(ab*0.4)
        theme.tcR,theme.tcG,theme.tcB=1.0,0.25,0.25
        theme.aoR,theme.aoG,theme.aoB=ar,ag,ab
        theme.amR,theme.amG,theme.amB=clamp01(ar*0.8+0.4),clamp01(ag*0.8+0.4),clamp01(ab*0.4)
        theme.abR,theme.abG,theme.abB=1.0,0.25,0.25
    end
end
-- =========================================================

require 'sampfuncs'
local sampev = require 'lib.samp.events'
local vkeys = require 'vkeys'
local imgui = require 'mimgui'
local effil = require 'effil'
-- LuaSocket идёт в комплекте с MoonLoader (его использует 'requests'), нужен
-- здесь только для локального HTTP-сервера, который слушает браузерный редактор окна
local ok_socket, socket = pcall(require, 'socket')
if not ok_socket then socket = nil end

-- ===================== SOUND & FONT =====================
local SOUND_DIR = getWorkingDirectory() .. "\\report_sounds\\"
local FONT_PATH = SOUND_DIR .. "MaybugMSRegular.ttf"
local FONT_URL  = "https://github.com/SaportBati/report1/raw/refs/heads/main/MaybugMSRegular.ttf"

local sounds = {
    ready     = false,
    caught    = SOUND_DIR .. "caught.mp3",
    enable    = SOUND_DIR .. "enable.mp3",
    disable   = SOUND_DIR .. "disable.mp3",
}

local function ensureSoundDir()
    if not doesDirectoryExist(SOUND_DIR) then
        createDirectory(SOUND_DIR)
    end
end


local function initSounds()
    ensureSoundDir()
    local base = "https://github.com/SaportBati/report1/raw/refs/heads/main/"
    local files = {
        { url = base .. "caught.mp3",    path = sounds.caught    },
        { url = base .. "enable.mp3",    path = sounds.enable    },
        { url = base .. "disable.mp3",   path = sounds.disable   },
    }

    local dlstatus = require('moonloader').download_status
    local remaining = #files

    local function onDownload(id, status, p1, p2)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            remaining = remaining - 1
            if remaining == 0 then
                sounds.ready = true
            end
        end
    end

    for _, f in ipairs(files) do
        if doesFileExist(f.path) then
            remaining = remaining - 1
        else
            downloadUrlToFile(f.url, f.path, onDownload)
        end
    end

    if remaining == 0 then
        sounds.ready = true
    end
end

local function playSound(path)
    if not sounds.ready then return end
    if not doesFileExist(path) then return end
    local stream = loadAudioStream(path)
    if stream then
        setAudioStreamVolume(stream, 0.3)
        setAudioStreamState(stream, 1)
    end
end
-- =========================================================

-- ===================== ICONS (PNG-байты из icons.txt) =====================
-- Формат файла: строки вида `Name = "\xHH\xHH...",` (без local/{}). Раньше
-- этот текст скармливался в loadstring("return { <содержимое> } ") — то есть
-- компилировался как Lua-код, из-за чего байты приходилось "задваивать"
-- (\\x89 вместо \x89), а локальный файл при этом почему-то сохранялся с
-- расширением .lua, хотя качается самый обычный .txt.
--
-- Ниже — та же самая схема загрузки картинок, что и в vipscaner.lua
-- (VIP_IMG_DATA / vipParseImgData / vipLoadTextureFromDataTable):
--   1) файл качается и хранится как .txt (без loadstring, без задвоенных
--      бэкслэшей — Lua-компилятор тут вообще не участвует);
--   2) содержимое парсится обычным string.gmatch по парам `Имя = "тело"`;
--   3) байты `\xHH` раскодируются в сырые PNG-байты (ICON_DATA[name]);
--   4) текстуры ImGui создаются лениво, по одной на имя, с кэшированием
--      факта попытки (attempted) — как в vipLoadTextureFromDataTable.
local ICONS_PATH = SOUND_DIR .. "icons.txt"
local ICONS_URL  = "https://github.com/SaportBati/report1/raw/refs/heads/main/icons.txt"

local ICON_DATA      = {}     -- "Имя" -> распакованные байты PNG (аналог VIP_IMG_DATA)
local iconDataParsed = false  -- true, если icons.txt уже прочитан и разобран
local iconTextures   = {}     -- "Имя" -> {tex, w, h, attempted} (аналог emojiTextures)

local function ensureIcons()
    ensureSoundDir()
    if doesFileExist(ICONS_PATH) then return end
    downloadUrlToFile(ICONS_URL, ICONS_PATH, function() end)
end

-- Раскодирует последовательности "\xHH" в реальные байты — один в один с
-- vipUnescapeImgString из vipscaner.lua.
local function unescapeIconString(s)
    return (s:gsub("\\x(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- Разбирает содержимое icons.txt как обычный текст (не Lua-код) через
-- gmatch по парам `Имя = "тело"` — один в один с vipParseImgData.
local function parseIconData(content)
    if not content then return end
    for name, str in content:gmatch('([%w_]+)%s*=%s*"(.-)"') do
        ICON_DATA[name] = unescapeIconString(str)
    end
end

-- Читает реальные ширину/высоту PNG прямо из заголовка IHDR (байты 17..24),
-- не полагаясь на размер бокса отрисовки. Нужно, чтобы иконки масштабировались
-- пропорционально их настоящему разрешению, а не растягивались/сжимались в
-- жёстко заданный квадрат (что и давало "мыльный"/искажённый результат).
-- Один в один с vipGetPngSizeFromMemory из vipscaner.lua.
local function getPngSizeFromMemory(data)
    if not data or #data < 24 then return nil, nil end
    local function be32(s, pos)
        local b1, b2, b3, b4 = s:byte(pos, pos + 3)
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end
    return be32(data, 17), be32(data, 21)
end

-- Читает icons.txt с диска и наполняет ICON_DATA. Вызывается лениво, один
-- раз при первом обращении к иконке (и повторно, если файл на диске ещё не
-- успел докачаться к этому моменту).
local function loadIconData()
    if iconDataParsed then return next(ICON_DATA) ~= nil end
    if not doesFileExist(ICONS_PATH) then return false end

    local f = io.open(ICONS_PATH, "rb")
    if not f then
        print("[icons] не удалось открыть icons.txt для чтения")
        iconDataParsed = true
        return false
    end
    local content = f:read("*a")
    f:close()

    parseIconData(content)

    if next(ICON_DATA) == nil then
        print("[icons] не удалось разобрать ни одной записи в icons.txt")
        iconDataParsed = true
        return false
    end

    iconDataParsed = true
    return true
end

-- Лениво создаёт текстуру ImGui для иконки по имени (или возвращает nil,
-- если байты ещё не скачаны/не распарсились — в этом случае вызывающий код
-- должен нарисовать fallback). Один в один со схемой
-- vipLoadTextureFromDataTable из vipscaner.lua: как только была предпринята
-- попытка (attempted), больше не пытаемся пересоздавать текстуру каждый кадр.
-- Безопасно вызывать из кадровых колбэков OnFrame — там ImGui уже проинициализирован.
local function getIconTexture(name)
    local cached = iconTextures[name]
    if cached and cached.attempted then
        if not cached.tex then return nil end
        return cached
    end

    if not loadIconData() then
        return nil
    end

    cached = iconTextures[name] or {}
    cached.attempted   = true
    iconTextures[name] = cached

    local raw = ICON_DATA[name]
    if not raw or raw == "" then
        cached.error = "иконка не найдена в icons.txt: " .. tostring(name)
        return nil
    end

    local w, h = getPngSizeFromMemory(raw)
    if not w or not h or w == 0 or h == 0 then
        cached.error = "не удалось прочитать PNG из памяти: " .. tostring(name)
        return nil
    end

    local ok, tex = pcall(imgui.CreateTextureFromFileInMemory, imgui.new('const char*', raw), #raw)
    if not ok or not tex then
        cached.error = tostring(tex)
        print("[icons] не удалось создать текстуру для " .. tostring(name) .. ": " .. tostring(tex))
        return nil
    end

    cached.tex, cached.w, cached.h = tex, w, h
    return cached
end

-- Возвращает {x0,y0,x1,y1} для AddImage так, чтобы картинка вписывалась в
-- размер targetSize по БОЛЬШЕЙ стороне с сохранением реальных пропорций
-- (entry.w/entry.h), центрированная в точке (cx, cy). Раньше иконки рисовались
-- в жёстко заданный квадрат без учёта реального разрешения/соотношения
-- сторон исходного PNG — из-за этого при несовпадении пропорций картинка либо
-- сплющивалась, либо занимала в боксе меньше места, чем нужно, и выглядела
-- размыто при масштабировании.
local function iconDrawRect(entry, cx, cy, targetSize)
    local scale = targetSize / math.max(entry.w, entry.h)
    local dw, dh = entry.w * scale, entry.h * scale
    return imgui.ImVec2(cx - dw/2, cy - dh/2), imgui.ImVec2(cx + dw/2, cy + dh/2)
end
-- ============================================================================

-- ===================== PING =====================
local ping = { val=0, flip={}, str="0" }

local function initPingFlip(str)
    ping.flip = {}
    for i = 1, #str do
        ping.flip[i] = { cur = str:sub(i,i), prev = str:sub(i,i), t = 1.0 }
    end
    ping.str = str
end

local function updatePingFlip(newStr)
    if #ping.flip ~= #newStr then
        initPingFlip(newStr)
        return
    end
    for i = 1, #newStr do
        local ch = newStr:sub(i,i)
        if ch ~= ping.flip[i].cur then
            ping.flip[i].prev = ping.flip[i].cur
            ping.flip[i].cur  = ch
            ping.flip[i].t    = 0.0
        end
    end
    ping.str = newStr
end

local function updatePing()
    local ok, myId = pcall(function() return select(2, sampGetPlayerIdByCharHandle(playerPed)) end)
    if ok and myId then
        local p = sampGetPlayerPing(myId)
        if p and p >= 0 then
            ping.val = p
            updatePingFlip(tostring(p))
        end
    end
end
-- ================================================

-- ===================== FLIP ANIMATION FOR TIMER =====================
-- для таймера каждый символ анимируется: падает вниз, заменяется, новый появляется
local tmr = { flip={}, str="00:00" }

local function initTimerFlip(str)
    tmr.flip = {}
    for i = 1, #str do
        tmr.flip[i] = { cur = str:sub(i,i), prev = str:sub(i,i), t = 1.0 }
    end
end

local function updateTimerFlip(newStr)
    if #tmr.flip ~= #newStr then
        initTimerFlip(newStr)
        tmr.str = newStr
        return
    end
    for i = 1, #newStr do
        local ch = newStr:sub(i,i)
        if ch ~= tmr.flip[i].cur then
            tmr.flip[i].prev = tmr.flip[i].cur
            tmr.flip[i].cur  = ch
            tmr.flip[i].t    = 0.0
        end
    end
    tmr.str = newStr
end
-- ====================================================================

-- ===================== ATTEMPTS SMOOTH COUNTER =====================
local att = { display=0.0, animStart=0.0, animDur=0.25, from=0, to=0 }

local function triggerAttemptsAnim(newVal)
    att.from      = att.display
    att.to        = newVal
    att.animStart = os.clock()
end
-- ===================================================================

-- анимация поимки репорта
local catchAnim = {
    active = false,
    startTime = 0
}

-- анимация появления окна
local slideAnim = {
    active = false,
    startTime = 0,
    duration = 400,
    offsetX = 0,
    offsetY = 0
}

-- анимация закрытия окна
local slideOutAnim = {
    active = false,
    startTime = 0,
    duration = 350,
    offsetX = 0,
    offsetY = 0
}

-- анимированное уведомление над окном (слот 1 - сверху)
local notifyAnim = {
    active = false,
    startTime = 0,
    duration = 2800,
    text = "",
    r = 1.0, g = 1.0, b = 1.0,
    useSmallFont = false,
    ending = false,
    endTime = 0,
    winOpen = imgui.new.bool(true), -- постоянный указатель, не пересоздаём каждый кадр
}

-- анимированное уведомление под окном (слот 2 - снизу)
local notifyAnim2 = {
    active = false,
    startTime = 0,
    duration = 2800,
    text = "",
    r = 1.0, g = 1.0, b = 1.0,
    useSmallFont = false,
    ending = false,
    endTime = 0,
    winOpen = imgui.new.bool(true), -- постоянный указатель, не пересоздаём каждый кадр
}

local function showNotify(text, r, g, b, duration, useSmallFont)
    local slot
    if not notifyAnim.active and not notifyAnim.ending then
        slot = notifyAnim
    elseif not notifyAnim2.active and not notifyAnim2.ending then
        slot = notifyAnim2
    else
        -- оба слота заняты: перезаписываем слот 2 и сразу в него
        notifyAnim2.active = false
        notifyAnim2.ending = false
        slot = notifyAnim2
    end
    slot.active    = true
    slot.ending    = false
    slot.startTime = os.clock()
    slot.endTime   = 0
    slot.duration  = duration
    slot.text      = text
    slot.r = r; slot.g = g; slot.b = b
    slot.useSmallFont = useSmallFont or false
end

local function hideNotify(slot)
    slot.ending = true
    slot.endTime = os.clock()
end

-- ffi definitions moved to top-level cdef block above

local function isGameFocused()
    local foreground = ffi.C.GetForegroundWindow()
    local gameWindow = ffi.C.FindWindowA("SAMP", nil)
    if gameWindow == nil or gameWindow == ffi.cast("void*", 0) then
        gameWindow = ffi.C.FindWindowA(nil, "Arizona RP")
    end
    return foreground == gameWindow
end

local showBox = effil.thread(function(text, caption)
    local ffi = require 'ffi'
    ffi.cdef[[
        int MessageBoxA(void* hWnd, const char* text, const char* caption, unsigned int type);
    ]]
    ffi.C.MessageBoxA(nil, text, caption, 0x40)
end)

local function notifyIfMinimized()
    if notifyMinimizedEnabled and not isGameFocused() then
        showBox("Репорт пойман!", "Report ~~load~~")
    end
end

local function checkLoadOrder()
    local logPath = getWorkingDirectory() .. "\\moonloader.log"
    local file = io.open(logPath, "r")
    if not file then return true end
    local content = file:read("*all")
    file:close()
    local myName = thisScript().name
    local myPos, toolsPos, i = nil, nil, 0
    for line in content:gmatch("[^\r\n]+") do
        i = i + 1
        if line:find("Loading script") then
            if line:find(myName, 1, true) then myPos = i end
            if line:find("arztools", 1, true) or line:find("Arizona Tools", 1, true) then toolsPos = i end
        end
    end
    if myPos and toolsPos then return myPos < toolsPos end
    return true
end

local function checkAndWarn()
    local ok = checkLoadOrder()
    if not ok then
        sampAddChatMessage("{FF0000}Ошибка: скрипт загружен после Arizona Tools!", 0xFF0000)
        return false
    end
    return true
end

local cfg = {
    key      = 0x45,
    cmd      = "/ot",
    count    = 3,
    delay    = 130,
    interval = 1200,
}

local GITHUB_OWNER = "SaportBati"
local GITHUB_FILE  = "users_encrypted.txt"
local v103         = "SaportBati_SecretKey_2024"
local CURRENT_VERSION = "2.4"
local WORKER_SITE_URL = "https://loadsite-api.grebenkinmatveyvyceslacovi2007.workers.dev/"
local SITE_URL        = "http://loadrep.ru"

-- VK key codes -> human readable names
local keyNames = {
    [0x01]="LMB",[0x02]="RMB",[0x04]="MMB",
    [0x08]="Backspace",[0x09]="Tab",[0x0D]="Enter",[0x10]="Shift",
    [0x11]="Ctrl",[0x12]="Alt",[0x1B]="Esc",[0x20]="Space",
    [0x21]="PageUp",[0x22]="PageDown",[0x23]="End",[0x24]="Home",
    [0x25]="Left",[0x26]="Up",[0x27]="Right",[0x28]="Down",
    [0x2E]="Delete",[0x2D]="Insert",
    [0x30]="0",[0x31]="1",[0x32]="2",[0x33]="3",[0x34]="4",
    [0x35]="5",[0x36]="6",[0x37]="7",[0x38]="8",[0x39]="9",
    [0x41]="A",[0x42]="B",[0x43]="C",[0x44]="D",[0x45]="E",
    [0x46]="F",[0x47]="G",[0x48]="H",[0x49]="I",[0x4A]="J",
    [0x4B]="K",[0x4C]="L",[0x4D]="M",[0x4E]="N",[0x4F]="O",
    [0x50]="P",[0x51]="Q",[0x52]="R",[0x53]="S",[0x54]="T",
    [0x55]="U",[0x56]="V",[0x57]="W",[0x58]="X",[0x59]="Y",[0x5A]="Z",
    [0x70]="F1",[0x71]="F2",[0x72]="F3",[0x73]="F4",[0x74]="F5",
    [0x75]="F6",[0x76]="F7",[0x77]="F8",[0x78]="F9",[0x79]="F10",
    [0x7A]="F11",[0x7B]="F12",
    [0x60]="Num0",[0x61]="Num1",[0x62]="Num2",[0x63]="Num3",[0x64]="Num4",
    [0x65]="Num5",[0x66]="Num6",[0x67]="Num7",[0x68]="Num8",[0x69]="Num9",
    [0x6A]="Num*",[0x6B]="Num+",[0x6D]="Num-",[0x6E]="Num.",[0x6F]="Num/",
    [0xBA]=";",[0xBB]="=",[0xBC]=",",[0xBD]="-",[0xBE]=".",[0xBF]="/",
    [0xC0]="`",[0xDB]="[",[0xDC]="\\",[0xDD]="]",[0xDE]="'",
}
local function getKeyName(code)
    return keyNames[code] or ("Key_" .. tostring(code))
end

local function themeColor32()
    local r = math.floor(theme.R * 255 + 0.5)
    local g = math.floor(theme.G * 255 + 0.5)
    local b = math.floor(theme.B * 255 + 0.5)
    return r * 65536 + g * 256 + b
end

local function themeHexStr()
    return string.format("%02X%02X%02X",
        math.floor(theme.R * 255 + 0.5),
        math.floor(theme.G * 255 + 0.5),
        math.floor(theme.B * 255 + 0.5))
end

-- Единый стиль сообщений: [{тема}Load?Report] {FFFFFF}текст
local function loadMsg(text)
    local hex = themeHexStr()
    sampAddChatMessage("{" .. hex .. "}[Load:zap:Report]:right: {FFFFFF}" .. text, themeColor32())
end

-- Subscription expiry (filled after whitelist check)
local subExpireTs = 0   -- 0 = eternal / unknown

-- Stats accumulators (reset after each upload)
local STATS_INTERVAL = 60
local st = {
    pingSum     = 0,
    pingSamples = 0,
    caughtDelta = 0,
    missedDelta = 0,
    activeSecs  = 0,
    lastCheck   = 0,
    cachedSha   = nil,
}


local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function b64decode(data)
    data = data:gsub('[^' .. b64chars .. '=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (b64chars:find(x) - 1)
        for i = 6, 1, -1 do r = r .. (f % math.pow(2,i) - f % math.pow(2,i-1) > 0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x < 8 then return '' end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i,i) == '1' and math.pow(2,8-i) or 0) end
        return string.char(c)
    end))
end

local function xorDecrypt(data, key)
    local result = {}
    for i = 1, #data do
        local ki = ((i - 1) % #key) + 1
        result[i] = string.char(bit.bxor(data:byte(i), key:byte(ki)))
    end
    return table.concat(result)
end

local function stripPrefix(name)
    return name:match("^%[%d+%](.+)$") or name
end

-- ===================== WHITELIST THREAD =====================
local whitelistThread = effil.thread(function(xorKey, playerName)
    local requests = require 'requests'
    local b64c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

    local function b64dec(data)
        data = data:gsub('[^' .. b64c .. '=]', '')
        return (data:gsub('.', function(x)
            if x == '=' then return '' end
            local r, f = '', (b64c:find(x) - 1)
            for i = 6, 1, -1 do r = r .. (f % math.pow(2,i) - f % math.pow(2,i-1) > 0 and '1' or '0') end
            return r
        end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
            if #x < 8 then return '' end
            local c = 0
            for i = 1, 8 do c = c + (x:sub(i,i) == '1' and math.pow(2,8-i) or 0) end
            return string.char(c)
        end))
    end

    local function xorDecCompat(data, key)
        local result = {}
        for i = 1, #data do
            local ki = ((i - 1) % #key) + 1
            local a, b = data:byte(i), key:byte(ki)
            local res, bit_val = 0, 1
            while a > 0 or b > 0 do
                local ab, bb = a % 2, b % 2
                if ab ~= bb then res = res + bit_val end
                a = math.floor(a / 2); b = math.floor(b / 2); bit_val = bit_val * 2
            end
            result[i] = string.char(res)
        end
        return table.concat(result)
    end

    local function stripPfx(name) return name:match("^%[%d+%](.+)$") or name end

    local function parseEntry(entry)
        local parts = {}
        for part in (entry .. "|"):gmatch("([^|]*)|") do
            table.insert(parts, part)
        end
        local nick   = parts[1] or entry
        local ts     = tonumber(parts[2]) or 0
        local prefix = (parts[3] and parts[3] ~= "") and parts[3] or nil
        local color  = (parts[4] and parts[4] ~= "") and parts[4] or nil
        return nick, ts, prefix, color
    end

    -- Worker /subs-api always returns fresh data (no-cache)
    local url = "https://api.loadrep.ru/subs-api?t=" .. tostring(os.time())
    local ok, res = pcall(function()
        return requests.get(url, { headers = { ["User-Agent"] = "MoonLoader", ["Cache-Control"] = "no-cache" } })
    end)
    if not ok or not res or res.status_code ~= 200 then
        return { status = "error", code = (res and res.status_code or 0) }
    end

    local cleanPlayer = stripPfx(playerName):lower()
    local found    = false
    local expireTs = 0
    local prefix   = nil
    local color    = nil

    for line in (res.text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local decoded      = b64dec(trimmed)
            local decrypted    = xorDecCompat(decoded, xorKey)
            local entryNick, entryExpire, entryPrefix, entryColor = parseEntry(decrypted)

            if stripPfx(entryNick):lower() == cleanPlayer then
                local now = os.time()
                if entryExpire == 0 or now <= entryExpire then
                    found    = true
                    expireTs = entryExpire
                    prefix   = entryPrefix
                    color    = entryColor
                end
                break
            end
        end
    end

    return { status = "success", found = found, expireTs = expireTs, prefix = prefix, color = color }
end)

-- ===================== SITE CHECK THREAD REMOVED =====================

-- ===================== VERSION / SCRIPT THREADS =====================
local versionCheckThread = effil.thread(function()
    local requests = require 'requests'
    local url = "https://github.com/SaportBati/report1/raw/refs/heads/main/version.txt"
    local ok, res = pcall(function()
        return requests.get(url, { headers = { ["User-Agent"] = "MoonLoader" } })
    end)
    if not ok or not res or res.status_code ~= 200 then return { error = true } end
    return { version = res.text:match("^%s*(.-)%s*$") }
end)

local LUAC_URL = "https://github.com/SaportBati/report1/raw/refs/heads/main/!load.luac"

-- Синхронная проверка актуальной версии (по схеме runWhitelistCheck) —
-- используется при старте скрипта, чтобы сразу вывести в чат версию из version.txt
function runVersionCheckSync()
    local t = versionCheckThread()
    local start = os.clock()
    while true do
        wait(100)
        local s = t:status()
        if s == "completed" then
            return t:get()
        elseif s == "failed" then
            return nil
        end
        if os.clock() - start > 15 then
            return nil
        end
    end
end

function announceCurrentVersion()
    print(("[DBG %.2f] announceCurrentVersion: проверка актуальной версии (version.txt) для вывода в чат"):format(os.clock()))
    local vok, vres = pcall(runVersionCheckSync)
    local actualVersion = (vok and vres and not vres.error and vres.version) and vres.version or CURRENT_VERSION
    print(("[DBG %.2f] announceCurrentVersion: актуальная версия=%s"):format(os.clock(), tostring(actualVersion)))
    loadMsg("Версия скрипта: {FFD700}" .. actualVersion)
end

-- ===================== ФУНКЦИЯ АВТО-ОБНОВЛЕНИЯ =====================
local function updateScript()
    print(("[DBG %.2f] updateScript: запуск versionCheckThread"):format(os.clock()))
    local runner = versionCheckThread()
    lua_thread.create(function()
        local t0 = os.clock()
        local timedOut = false
        -- ВАЖНО: у effil-потока статус во время работы называется "running",
        -- а не "working" (как было раньше) — из-за этого условие цикла было
        -- всегда ложным, и скрипт сразу проваливался в блокирующий runner:get(),
        -- который синхронно фризил игру на всё время сетевого запроса.
        while true do
            local s = runner:status()
            if s == "completed" or s == "failed" then break end
            wait(100)
            if os.clock() - t0 > 15 then
                print(("[DBG %.2f] updateScript: ТАЙМАУТ 15 сек ожидания versionCheckThread, прерываем БЕЗ вызова get()"):format(os.clock()))
                timedOut = true
                break
            end
        end

        if timedOut then
            -- НЕ вызываем runner:get() — поток ещё не закончил работу (сервер не
            -- ответил), и get() заблокировал бы игру ещё на неопределённое время,
            -- пока фактический сетевой запрос внутри effil-потока не завершится.
            -- Просто отпускаем проверку версии в этом запуске — effil-поток
            -- доработает сам в фоне и будет автоматически уничтожен GC.
            print(("[DBG %.2f] updateScript: пропускаем эту проверку версии, поток оставлен в фоне"):format(os.clock()))
            return
        end

        print(("[DBG %.2f] updateScript: цикл ожидания завершён штатно (status=%s) за %.2f сек"):format(os.clock(), runner:status(), os.clock()-t0))
        local okGet, result = pcall(function() return runner:get() end)
        if not okGet then
            print(("[DBG %.2f] updateScript: runner:get() выбросил ошибку: %s"):format(os.clock(), tostring(result)))
            result = nil
        end
        
        if result and result.version then
            local cloudVersion = result.version:gsub("%s+", "")
            print(("[DBG %.2f] updateScript: версия на сервере=%s, текущая=%s"):format(os.clock(), cloudVersion, CURRENT_VERSION))
            if cloudVersion ~= CURRENT_VERSION then
                sampAddChatMessage("{3498db}[Report Load]: {ffffff}Найдено обновление! Загрузка версии " .. cloudVersion, -1)
                local scriptPath = thisScript().path
                print(("[DBG %.2f] updateScript: скачивание нового файла скрипта началось"):format(os.clock()))
                downloadUrlToFile(LUAC_URL, scriptPath, function(id, status, p1, p2)
                    if status == 6 then -- STATUS_ENDDOWNLOADDATA
                        print(("[DBG %.2f] updateScript: скачивание завершено, релоад скрипта"):format(os.clock()))
                        sampAddChatMessage("{3498db}[Report Load]: {ffffff}Скрипт успешно обновлен и перезагружен!", -1)
                        thisScript():reload()
                    end
                end)
            end
        else
            print(("[DBG %.2f] updateScript: не удалось получить версию с сервера (result=%s)"):format(os.clock(), tostring(result)))
        end
    end)
end
-- ===================================================================

-- ===================== STATS THREAD =====================
local statsUpdateThread = effil.thread(function(
        workerUrl,
        playerName, cachedSha,
        pingAvg, caughtDelta, missedDelta, activeSecsDelta)

    local requests = require 'requests'

    local cur_sha = cachedSha or ""
    local cur_caught, cur_missed, cur_time_sec, cur_avg_ping = 0, 0, 0, 0
    local get_s = 0

    local rok, rres = pcall(function()
        return requests.get(workerUrl .. "/stats?nick=" .. playerName, {
            headers = { ["User-Agent"] = "MoonLoader" }
        })
    end)
    if rok and rres then
        get_s = rres.status_code or 0
        if rres.status_code == 200 then
            local sha_found = rres.text:match('"sha"%s*:%s*"([^"]+)"')
            if sha_found then cur_sha = sha_found end
            if rres.text:find('"found"%s*:%s*true') then
                local function getNum(k) return tonumber(rres.text:match('"' .. k .. '"%s*:%s*([%d%.]+)')) or 0 end
                cur_caught   = getNum("total_caught")
                cur_missed   = getNum("total_missed")
                cur_time_sec = getNum("total_time_sec")
                cur_avg_ping = getNum("avg_ping")
            end
        end
    end

    local new_caught   = cur_caught   + caughtDelta
    local new_missed   = cur_missed   + missedDelta
    local new_time_sec = cur_time_sec + activeSecsDelta
    local new_ping     = pingAvg > 0 and math.floor((cur_avg_ping + pingAvg) / 2 + 0.5) or cur_avg_ping
    local now_ts       = math.floor(os.time())

    local shaField = (cur_sha ~= "") and (',"sha":"' .. cur_sha .. '"') or ""
    local postBody = string.format(
        '{"nick":"%s"%s,"data":{"total_caught":%d,"total_missed":%d,"total_time_sec":%d,"avg_ping":%d,"last_updated":%d}}',
        playerName, shaField, new_caught, new_missed, new_time_sec, new_ping, now_ts
    )

    local post_s = 0
    local new_sha = ""
    local wok, wres = pcall(function()
        return requests.post(workerUrl .. "/stats", {
            headers = { ["User-Agent"] = "MoonLoader", ["Content-Type"] = "application/json" },
            data = postBody
        })
    end)
    if wok and wres then
        post_s = wres.status_code or 0
        new_sha = wres.text:match('"sha"%s*:%s*"([^"]+)"') or ""
    end

    return { get_s = get_s, post_s = post_s, sha = new_sha }
end)

local function runStatsUpdate(playerName, pingAvg, caughtDelta, missedDelta, activeSecsDelta)
    local t = statsUpdateThread(
        WORKER_SITE_URL,
        playerName, st.cachedSha or "",
        pingAvg, caughtDelta, missedDelta, activeSecsDelta)
    lua_thread.create(function()
        local t0 = os.clock()
        while true do
            wait(300)
            local s = t:status()
            if s == "completed" then
                local ok2, r = pcall(function() return t:get() end)
                if ok2 and r then
                    if r.sha and r.sha ~= "" then st.cachedSha = r.sha end
                end
                return
            elseif s == "failed" then return end
            if os.clock() - t0 > 25 then return end
        end
    end)
end

local function runWhitelistCheck(playerName)
    print(("[DBG %.2f] runWhitelistCheck: старт потока whitelistThread"):format(os.clock()))
    local t = whitelistThread(v103, playerName)
    local start = os.clock()
    local lastPrint = start
    while true do
        wait(100)
        local s = t:status()
        if os.clock() - lastPrint > 1.0 then
            print(("[DBG %.2f] runWhitelistCheck: ожидание, status=%s, прошло %.1f сек"):format(os.clock(), tostring(s), os.clock()-start))
            lastPrint = os.clock()
        end
        if s == "completed" then
            print(("[DBG %.2f] runWhitelistCheck: ЗАВЕРШЕНО за %.2f сек"):format(os.clock(), os.clock()-start))
            return t:get()
        elseif s == "failed" then
            print(("[DBG %.2f] runWhitelistCheck: ОШИБКА ПОТОКА (failed) за %.2f сек"):format(os.clock(), os.clock()-start))
            return nil
        end
        if os.clock() - start > 12 then
            print(("[DBG %.2f] runWhitelistCheck: ТАЙМАУТ 12 сек, поток не ответил"):format(os.clock()))
            return nil
        end
    end
end

-- ===================== COLOR CHANGE THREAD =====================
local colorChangeThread = effil.thread(function(workerUrl, playerName, color)
    local ok, result = pcall(function()
        local requests = require 'requests'
        local cleanNick = playerName:match("^%[%d+%](.+)$") or playerName
        local body = string.format('{"nick":"%s","color":"%s"}', cleanNick, color)
        local rok, res = pcall(function()
            return requests.post(workerUrl .. "/user-color", {
                headers = { ["User-Agent"] = "MoonLoader", ["Content-Type"] = "application/json" },
                data = body
            })
        end)
        if not rok or not res then return { status = 0, error = "request_failed" } end
        local status = res.status_code or 0
        local text = (type(res.text) == "string") and res.text or ""
        local retry_after = tonumber(text:match('"retry_after"%s*:%s*(%d+)')) or 0
        local err = text:match('"error"%s*:%s*"([^"]+)"') or ""
        return { status = status, error = err, retry_after = retry_after }
    end)
    if ok and result then return result end
    return { status = 0, error = "internal_error" }
end)

-- Схема 1-в-1 как у runWhitelistCheck (который работает стабильно при старте
-- скрипта): один блокирующий синхронный хелпер, без callback-параметра и без
-- вложенного lua_thread.create внутри него. Вызывающий код сам оборачивает
-- вызов в pcall + один lua_thread.create — как это уже сделано для проверки подписки.
local function runColorChangeSync(playerName, color)
    local t = colorChangeThread(WORKER_SITE_URL, playerName, color)
    local start = os.clock()
    while true do
        wait(100)
        local s = t:status()
        if s == "completed" then return t:get()
        elseif s == "failed" then return nil end
        if os.clock() - start > 20 then return nil end
    end
end
-- ===============================================================


-- ===================== LOAD MENU STATE =====================
local menu = {
    win      = imgui.new.bool(false),
    state    = "idle",   -- idle / opening / open / dismissing
    stateTime= 0.0,
    alpha    = 0.0,
    slideY   = 0.0,
    -- subscription check
    subState = "idle",   -- idle / checking / done
    subMsg   = "",
    subIsOk  = false,
    subTime  = 0.0,
}

local function openMenu()
    menu.state     = "opening"
    menu.stateTime = os.clock()
    menu.alpha     = 0.0
    menu.slideY    = 28.0
    menu.win[0]    = true
    menu.subState  = "idle"
    menu.subMsg    = ""
end

local function closeMenu()
    menu.state     = "dismissing"
    menu.stateTime = os.clock()
end
-- ============================================================

-- ===================== SUBSCRIPTION ERROR WINDOW STATE =====================
-- Показывается, когда сервер проверки подписки не отвечает (таймаут, сетевая
-- ошибка, неожиданный ответ) — вместо краша/остановки скрипта даём пользователю
-- возможность повторить попытку, не перезапуская скрипт.
local subErr = {
    win           = imgui.new.bool(false),
    state         = "idle",   -- idle / opening / open / dismissing
    stateTime     = 0.0,
    alpha         = 0.0,
    slideY        = 0.0,
    reason        = "",
    checking      = false,
    retryRequested= false,
}

local function openSubErrWindow(reason)
    subErr.reason         = reason or u8"Неизвестная ошибка"
    subErr.checking       = false
    subErr.retryRequested = false
    subErr.state          = "opening"
    subErr.stateTime      = os.clock()
    subErr.alpha          = 0.0
    subErr.slideY         = 28.0
    subErr.win[0]         = true
end

local function closeSubErrWindow()
    subErr.state     = "dismissing"
    subErr.stateTime = os.clock()
end
-- =============================================================================

local showWindow = imgui.new.bool(false)
local fonts = {} -- title,info,missed,actTitle,actBody,actBtn,actSmall

-- ===================== COLOR PICKER STATE =====================
local cp = {
    win        = imgui.new.bool(false),
    -- отдельный постоянный указатель для окна превью (раньше создавался
    -- заново imgui.new.bool(true) каждый кадр, пока пикер открыт — это
    -- лишние FFI-аллокации на каждый кадр, что могло приводить к
    -- нестабильности/крашам при долгой работе с пикером)
    previewWinOpen = imgui.new.bool(true),
    state      = "idle",   -- idle / opening / open / saving / dismissing
    stateTime  = 0.0,
    alpha      = 0.0,
    slideY     = 0.0,
    -- HSV рабочие переменные
    hue        = 0.0,   -- 0..1
    sat        = 0.8,
    val        = 0.9,
    -- превью (применяется live)
    previewHex = "",
    -- оригинальный цвет до открытия пикера (для отката при отмене)
    originalColor = nil,   -- nil = дефолт, иначе "#RRGGBB"
    -- hex input buffer
    hexBuf     = imgui.new.char[8](0),
    -- drag state для цветового круга
    draggingWheel = false,
    draggingSV    = false,
    -- статус сохранения
    saveStatus = "",
    saveIsErr  = false,
    playerName = "",
    -- защита от повторной/параллельной отправки запроса на сохранение цвета
    saveActive = false,
    -- увеличивается при каждом открытии пикера — позволяет отличить
    -- актуальный колбэк сохранения от устаревшего (если пикер успели
    -- закрыть/переоткрыть, пока ответ от сервера ещё не пришёл)
    session = 0,
}

-- RGB <-> HSV helpers (для пикера)
local function rgbToHsv(r, g, b)
    local max = math.max(r, g, b)
    local min = math.min(r, g, b)
    local d   = max - min
    local h, s, v = 0, 0, max
    if max ~= 0 then s = d / max end
    if d ~= 0 then
        if     max == r then h = (g - b) / d + (g < b and 6 or 0)
        elseif max == g then h = (b - r) / d + 2
        else               h = (r - g) / d + 4
        end
        h = h / 6
    end
    return h, s, v
end

local function hsvToRgb(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t2 = v * (1 - (1 - f) * s)
    local r, g, b
    local m = i % 6
    if     m == 0 then r,g,b = v,t2,p
    elseif m == 1 then r,g,b = q,v,p
    elseif m == 2 then r,g,b = p,v,t2
    elseif m == 3 then r,g,b = p,q,v
    elseif m == 4 then r,g,b = t2,p,v
    else               r,g,b = v,p,q
    end
    return r, g, b
end

local function rgbToHex(r, g, b)
    return string.format("#%02X%02X%02X",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
end

-- ===================== HUE WHEEL CACHE =====================
-- Само кольцо оттенков (положение точек по кругу и цвет каждого сегмента)
-- не зависит от кадра — оно всегда одно и то же. Раньше эти значения
-- (sin/cos + hsvToRgb) пересчитывались заново 64 раза за КАЖДЫЙ кадр,
-- пока окно пикера открыто — лишняя нагрузка на CPU/GC. Считаем один раз.
local WHEEL_SEGS = 64
local wheelCache = {}
for i = 0, WHEEL_SEGS - 1 do
    local a = (i / WHEEL_SEGS) * math.pi * 2
    local h = i / WHEEL_SEGS
    local r, g, b = hsvToRgb(h, 1, 1)
    wheelCache[i] = { cosA = math.cos(a), sinA = math.sin(a), r = r, g = g, b = b }
end
wheelCache[WHEEL_SEGS] = wheelCache[0] -- замыкаем круг (угол 2? == углу 0)
-- =============================================================

local function hexToRgb(hex)
    hex = hex:gsub("^#", "")
    if #hex ~= 6 then return nil end
    local r = tonumber(hex:sub(1,2), 16)
    local g = tonumber(hex:sub(3,4), 16)
    local b = tonumber(hex:sub(5,6), 16)
    if not (r and g and b) then return nil end
    return r/255, g/255, b/255
end

local function cpSyncHexBuf()
    local r, g, b = hsvToRgb(cp.hue, cp.sat, cp.val)
    cp.previewHex = rgbToHex(r, g, b)
    local hexStr  = cp.previewHex:gsub("^#", "")
    ffi.copy(cp.hexBuf, hexStr)
end

local function openColorPicker(playerName)
    -- новая сессия пикера — любой колбэк сохранения от предыдущей сессии
    -- (если она ещё не завершилась) будет считаться устаревшим
    cp.session = cp.session + 1
    cp.saveActive = false
    -- сохраняем оригинальный цвет для отката при отмене
    cp.originalColor = theme.color and ("#" .. theme.color) or nil
    -- инициализируем HSV из текущего theme.color
    local hr, hg, hb = theme.R, theme.G, theme.B
    if theme.color then
        local tr, tg, tb = hexToRgb("#" .. theme.color)
        if tr then hr, hg, hb = tr, tg, tb end
    end
    cp.hue, cp.sat, cp.val = rgbToHsv(hr, hg, hb)
    cp.playerName  = playerName
    cp.saveStatus  = ""
    cp.saveIsErr   = false
    cp.state       = "opening"
    cp.stateTime   = os.clock()
    cp.alpha       = 0.0
    cp.slideY      = 30.0
    cp.draggingWheel = false
    cp.draggingSV    = false
    cpSyncHexBuf()
    cp.win[0] = true
end
-- ==============================================================

local window = {
    x = 100, y = 100,
    w = 250, h = 68,
    isInitialized = false
}

imgui.OnInitialize(function()
    local glyph_ranges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()

    local chosen_font
    if doesFileExist(FONT_PATH) then
        chosen_font = FONT_PATH
    else
        chosen_font = getFolderPath(0x14) .. '\\trebuc.ttf'
    end

    fonts.title  = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 19.0, nil, glyph_ranges)
    fonts.info   = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 16.0, nil, glyph_ranges)
    fonts.missed = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 26.0, nil, glyph_ranges)
    fonts.actTitle    = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 21.0, nil, glyph_ranges)
    fonts.actBody     = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 16.0, nil, glyph_ranges)
    fonts.actBtn      = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 17.0, nil, glyph_ranges)
    fonts.actSmall    = imgui.GetIO().Fonts:AddFontFromFileTTF(chosen_font, 14.0, nil, glyph_ranges)
    imgui.GetStyle().WindowRounding = 12.0
    imgui.GetStyle().Colors[imgui.Col.WindowBg] = imgui.ImVec4(0.06, 0.06, 0.06, 0.94)
    window.isInitialized = true
end)

local function BuildRoundedRectPath(pos, size, radius, segments)
    segments = segments or 8
    local x, y = pos.x, pos.y
    local w, h = size.x, size.y
    local r = math.min(radius, w/2, h/2)
    local points = {}
    local corners = {
        {x + w - r, y + r,     -math.pi*0.5, 0           },
        {x + w - r, y + h - r, 0,            math.pi*0.5 },
        {x + r,     y + h - r, math.pi*0.5,  math.pi     },
        {x + r,     y + r,     math.pi,      math.pi*1.5 },
    }
    for _, c in ipairs(corners) do
        local cx, cy, a1, a2 = c[1], c[2], c[3], c[4]
        for i = 0, segments do
            local a = a1 + (a2 - a1) * (i / segments)
            points[#points+1] = {cx + math.cos(a) * r, cy + math.sin(a) * r}
        end
    end
    points[#points+1] = points[1]
    return points
end

local function BuildPathLengths(path)
    local lens, total = {}, 0
    for i = 1, #path - 1 do
        local dx = path[i+1][1] - path[i][1]
        local dy = path[i+1][2] - path[i][2]
        local l  = math.sqrt(dx*dx + dy*dy)
        lens[#lens+1] = l
        total = total + l
    end
    return lens, total
end

local function DrawDashedBorder(dl, pos, size, time, alpha)
    alpha = alpha or 1.0
    local borderColor = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, alpha))
    local dashLen, gapLen, speed, thickness, radius =
        winCfg.dashLen, winCfg.gapLen, winCfg.dashSpeed, winCfg.borderThickness, winCfg.cornerRadius
    local step = dashLen + gapLen
    local m = 1.0
    local mpos  = imgui.ImVec2(pos.x + m, pos.y + m)
    local msize = imgui.ImVec2(size.x - m*2, size.y - m*2)
    -- Число сегментов на угол подбираем так, чтобы длина одного мини-отрезка дуги
    -- была намного меньше штриха/пробела — иначе на грубой дуге (было фиксировано 8)
    -- пунктир при перерисовке "мигает" рывками и на глаз кажется, что на углах
    -- бежит в обратную сторону (алиасинг), хотя путь построен непрерывно и в одном
    -- направлении по всему периметру.
    local arcLen = math.max(1, radius) * (math.pi / 2)
    local cornerSegs = math.max(8, math.min(48, math.ceil(arcLen / math.max(1.0, math.min(dashLen, gapLen) * 0.35))))
    local path = BuildRoundedRectPath(mpos, msize, radius, cornerSegs)
    local lens, total = BuildPathLengths(path)
    local animPos = (time * speed) % total
    local walked  = 0
    for i = 1, #path - 1 do
        local p1, p2, len = path[i], path[i+1], lens[i]
        if len < 0.001 then
            walked = walked + len
        else
            local dx, dy = (p2[1] - p1[1]) / len, (p2[2] - p1[2]) / len
            local offset = (animPos - walked) % step
            local curr   = -offset
            while curr < len do
                local ss = math.max(0, curr)
                local ee = math.min(len, curr + dashLen)
                if ee > ss then
                    dl:AddLine(
                        imgui.ImVec2(p1[1] + dx * ss, p1[2] + dy * ss),
                        imgui.ImVec2(p1[1] + dx * ee, p1[2] + dy * ee),
                        borderColor, thickness
                    )
                end
                curr = curr + step
            end
            walked = walked + len
        end
    end
end

-- ===================== DRAW FLIP DIGIT =====================
-- рисует один символ с эффектом переворачивания (как табло)
-- prev старый символ, cur следующий символ
local function DrawFlipChar(dl, font, x, y, charData, baseColor, clipMin, clipMax)
    local ch  = charData.cur
    local prv = charData.prev
    local t   = charData.t

    -- плавный easing
    local ease = t * t * (3 - 2 * t)
    local charH = 16  -- высота символа (примерно)

    -- анимируем смену: t от 0?1
    -- prev: уходит вниз на charH
    -- cur:  приходит сверху, смещение charH*(1-ease) ? 0

    if t < 1.0 then
        -- старый символ (prev) с анимацией вниз
        local prevOffY = charH * ease
        local prevAlpha = 1.0 - ease
        dl:PushClipRect(clipMin, clipMax, true)
        dl:AddText(
            imgui.ImVec2(x, y + prevOffY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(baseColor[1], baseColor[2], baseColor[3], baseColor[4] * prevAlpha)),
            prv
        )
        -- новый символ (cur) с анимацией сверху
        local curOffY = charH * (1.0 - ease)
        local curAlpha = ease
        dl:AddText(
            imgui.ImVec2(x, y - curOffY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(baseColor[1], baseColor[2], baseColor[3], baseColor[4] * curAlpha)),
            ch
        )
        dl:PopClipRect()
    else
        -- статичный символ
        dl:PushClipRect(clipMin, clipMax, true)
        dl:AddText(
            imgui.ImVec2(x, y),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(baseColor[1], baseColor[2], baseColor[3], baseColor[4])),
            ch
        )
        dl:PopClipRect()
    end
end
-- ===========================================================

local function DrawContent(drawList, pos, time, isGlowPass, globalAlpha)
    local colMult = isGlowPass and globalAlpha or 1.0

    local textFade = 1.0
    if catchAnim.active then
        local elapsed = (os.clock() - catchAnim.startTime) * 1000
        if elapsed < 500 then
            textFade = 1.0
        elseif elapsed < 1200 then
            local t = (elapsed - 500) / 700
            textFade = 1.0 - t * t * (3 - 2 * t)
        else
            textFade = 0.0
        end
    end

    local function GetCol(r, g, b, a)
        return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a * colMult))
    end
    local function GetColText(r, g, b, a)
        return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a * colMult * textFade))
    end

    -- ===== ЗАГОЛОВОК (произвольный текст, по умолчанию "Ловля..") =====
    -- Позиция берётся из winCfg.titleX/titleY — те же координаты, что и в
    -- браузерном редакторе, поэтому расположение больше не "плывёт" между
    -- предпросмотром и игрой.
    if winCfg.title ~= "" then
        imgui.PushFont(fonts.title)
        local titleText = (winCfg.title)
        drawList:AddText(
            imgui.ImVec2(pos.x + winCfg.titleX, pos.y + winCfg.titleY),
            isGlowPass and GetColText(1,1,1,1) or GetColText(theme.R,theme.G,theme.B,1),
            titleText
        )
        imgui.PopFont()
    end

    -- ===== PING: текст "Ping: " + flip-анимация цифр =====
    if winCfg.showPing then
        imgui.PushFont(fonts.title)
        local pingVal = ping.val
        local pr, pg, pb
        if pingVal < 70 then
            pr, pg, pb = theme.pgR, theme.pgG, theme.pgB
        elseif pingVal <= 100 then
            pr, pg, pb = theme.pmR, theme.pmG, theme.pmB
        else
            pr, pg, pb = theme.pbR, theme.pbG, theme.pbB
        end

        -- вычисляем цвет пинга
        if #ping.flip == 0 then
            initPingFlip(tostring(ping))
        end

        -- отрисовываем "Ping: " обычным способом
        local charW_ping = 11
        local labelText  = "Ping: "
        local pingStartX = pos.x + winCfg.pingX
        local pingStartY = pos.y + winCfg.pingY

        local pingLabelColor = isGlowPass
            and GetColText(1,1,1,1)
            or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.mR, theme.mG, theme.mB, 1.0 * colMult * textFade))

        drawList:AddText(
            imgui.ImVec2(pingStartX, pingStartY),
            pingLabelColor,
            labelText
        )

        -- цифры пинга начинаются сразу после текста "Ping: " + 2px отступ
        local labelPixelW  = imgui.CalcTextSize(labelText).x
        local digitsStartX = pingStartX + labelPixelW + 2
        local digitsW      = #ping.flip * charW_ping

        local pingDigitColor = { pr, pg, pb, 1.0 * colMult * textFade }
        local clipMinP = imgui.ImVec2(digitsStartX - 2, pingStartY - 2)
        local clipMaxP = imgui.ImVec2(digitsStartX + digitsW + 4, pingStartY + 18)

        local dX = digitsStartX
        for i, cd in ipairs(ping.flip) do
            DrawFlipChar(drawList, fonts.title, dX, pingStartY, cd, pingDigitColor, clipMinP, clipMaxP)
            dX = dX + charW_ping
        end
        imgui.PopFont()
    end

    -- ===== ТАЙМЕР =====
    imgui.PushFont(fonts.info)
    local diff  = startTime ~= 0 and (os.time() - startTime) or 0

    -- цвет таймера
    local tr, tg, tb = theme.toR, theme.toG, theme.toB
    if     diff >= 90 then tr, tg, tb = theme.tcR, theme.tcG, theme.tcB
    elseif diff >= 30 then tr, tg, tb = theme.twR, theme.twG, theme.twB end

    local timerBaseColor = { tr, tg, tb, 1.0 * colMult * textFade }

    -- обновляем строку таймера с эффектом flip
    local newTimerStr = string.format("%02d:%02d", math.floor(diff/60), diff%60)
    if #tmr.flip == 0 then
        initTimerFlip(newTimerStr)
    else
        updateTimerFlip(newTimerStr)
    end

    -- рисуем цифры таймера через flip-анимацию
    local charW = 10  -- примерная ширина символа для fonts.info 16px
    local timerX = pos.x + winCfg.timerX
    local timerY = pos.y + winCfg.timerY
    local curX  = timerX
    local clipMin = imgui.ImVec2(curX - 2, timerY - 2)
    local clipMax = imgui.ImVec2(curX + charW * #tmr.flip + 4, timerY + 18)

    if winCfg.showTimer then
        for i, cd in ipairs(tmr.flip) do
            DrawFlipChar(drawList, fonts.info, curX, timerY, cd, timerBaseColor, clipMin, clipMax)
            curX = curX + charW
            -- добавляем ':' если нужен
            if i == 2 then curX = curX - -1 end
            if i == 3 then curX = curX - 4 end
        end
    end

    -- ===== попытки с плавным значением =====
    -- обновляем анимацию счётчика
    local now = os.clock()
    local animElapsed = now - att.animStart
    if animElapsed < att.animDur then
        local t2 = animElapsed / att.animDur
        local ease2 = t2 * t2 * (3 - 2 * t2)
        att.display = att.from + (att.to - att.from) * ease2
    else
        att.display = att.to
    end

    -- округляем для отображения
    local attemptsShown = math.floor(att.display + 0.5)

    -- эффект пульса при изменении: яркий скачок
    local attemptsAlpha = 1.0
    if animElapsed < att.animDur then
        local pulse = math.sin((animElapsed / att.animDur) * math.pi)
        attemptsAlpha = 1.0 + pulse * 0.4  -- пик идёт к яркому цвету
        if attemptsAlpha > 1.0 then attemptsAlpha = 1.0 end
    end

    local attX = pos.x + winCfg.attemptsX
    local attY = pos.y + winCfg.attemptsY

    -- цвет попыток попытки
    local ar, ag, ab
    if attemptsShown <= 3 then
        ar, ag, ab = theme.aoR, theme.aoG, theme.aoB
    elseif attemptsShown <= 5 then
        ar, ag, ab = theme.amR, theme.amG, theme.amB
    else
        ar, ag, ab = theme.abR, theme.abG, theme.abB
    end

    -- ширина текста метки fonts.info размера (мы уже внутри PushFont(fonts.info))
    local labelW2 = imgui.CalcTextSize(u8"Попыток: ").x

    if winCfg.showAttempts then
        -- "Попыток: " серым
        drawList:AddText(
            imgui.ImVec2(attX, attY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.mR, theme.mG, theme.mB, attemptsAlpha * colMult * textFade)),
            u8"Попыток: "
        )
        -- Цифра цветная
        drawList:AddText(
            imgui.ImVec2(attX + labelW2, attY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(ar, ag, ab, attemptsAlpha * colMult * textFade)),
            tostring(attemptsShown)
        )
    end

    -- ===== пропущено (новый компонент) =====
    if winCfg.showMissed then
        local missedX = pos.x + winCfg.missedX
        local missedY = pos.y + winCfg.missedY
        local labelW3 = imgui.CalcTextSize(u8"Пропущено: ").x
        drawList:AddText(
            imgui.ImVec2(missedX, missedY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.mR, theme.mG, theme.mB, colMult * textFade)),
            u8"Пропущено: "
        )
        drawList:AddText(
            imgui.ImVec2(missedX + labelW3, missedY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.pbR, theme.pbG, theme.pbB, colMult * textFade)),
            tostring(missedCount)
        )
    end

    -- ===== произвольный текст (новый компонент) =====
    if winCfg.showCustom and winCfg.customText ~= "" then
        drawList:AddText(
            imgui.ImVec2(pos.x + winCfg.customX, pos.y + winCfg.customY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.85, 0.85, 0.85, colMult * textFade)),
            (winCfg.customText)
        )
    end

    imgui.PopFont()

    -- ===== кружок и анимация поимки (при активации) =====
    if catchAnim.active then
        local elapsed = (os.clock() - catchAnim.startTime) * 1000
        local cx = pos.x + window.w - 35
        local cy = pos.y + window.h / 2 + 4

        local function drawCheckmark(cx2, cy2, scale, alpha)
            local s = scale
            drawList:AddLine(imgui.ImVec2(cx2-7*s, cy2+1*s), imgui.ImVec2(cx2-2*s, cy2+6*s), GetCol(1,1,1,alpha), 2.5)
            drawList:AddLine(imgui.ImVec2(cx2-2*s, cy2+6*s), imgui.ImVec2(cx2+7*s, cy2-5*s), GetCol(1,1,1,alpha), 2.5)
        end

        if elapsed < 500 then
            local t = elapsed / 500
            local ease = t * t * (3 - 2 * t)
            local waveFade = 1.0 - ease
            local waveX, waveY, waveWidth = pos.x + 165, pos.y + 38, 70
            local function drawWave(wSpeed, opacity)
                local off = math.sin(time * wSpeed) * 15
                local p1  = imgui.ImVec2(waveX,                    waveY)
                local p2  = imgui.ImVec2(waveX + waveWidth * 0.5,  waveY)
                local p3  = imgui.ImVec2(waveX + waveWidth,        waveY)
                local cp1 = imgui.ImVec2(waveX + waveWidth * 0.25, waveY - off)
                local cp2 = imgui.ImVec2(waveX + waveWidth * 0.75, waveY + off)
                drawList:AddBezierCurve(p1, cp1, cp1, p2, GetCol(1,1,1, opacity * waveFade), 2.2)
                drawList:AddBezierCurve(p2, cp2, cp2, p3, GetCol(1,1,1, opacity * waveFade), 2.2)
            end
            drawWave(3.5, 0.2); drawWave(2.5, 0.4); drawWave(1.8, 0.6)
            local r = 14 * ease
            if r > 0.5 then
                drawList:AddCircleFilled(imgui.ImVec2(cx, cy), r, GetCol(0, 0.85, 0.3, ease), 32)
            end
            if ease > 0.3 then
                drawCheckmark(cx, cy, ease * 0.85 + 0.15, (ease - 0.3) / 0.7)
            end

        elseif elapsed < 1500 then
            local t = (elapsed - 500) / 1000
            local ease = t * t * (3 - 2 * t)
            local circleAlpha = 1.0 - ease
            drawList:AddCircleFilled(imgui.ImVec2(cx, cy), 14, GetCol(0, 0.85, 0.3, circleAlpha), 32)
            if circleAlpha > 0.05 then
                drawCheckmark(cx, cy, 1.0, circleAlpha)
            end
            imgui.PushFont(fonts.title)
            drawList:AddText(
                imgui.ImVec2(pos.x + window.w/2 - 38, pos.y + window.h/2 - 9),
                GetCol(1, 1, 1, ease),
                u8"Поймал!"
            )
            imgui.PopFont()

        elseif elapsed < 2500 then
            local t = (elapsed - 1500) / 1000
            local alpha = 1.0 - t * t * (3 - 2 * t)
            imgui.PushFont(fonts.title)
            drawList:AddText(
                imgui.ImVec2(pos.x + window.w/2 - 38, pos.y + window.h/2 - 9),
                GetCol(1, 1, 1, alpha),
                u8"Поймал!"
            )
            imgui.PopFont()
        end
    else
        local waveX, waveY, waveWidth = pos.x + 165, pos.y + 36, 70
        local function drawWave(wSpeed, opacity)
            local off = math.sin(time * wSpeed) * 15
            local p1  = imgui.ImVec2(waveX,                    waveY)
            local p2  = imgui.ImVec2(waveX + waveWidth * 0.5,  waveY)
            local p3  = imgui.ImVec2(waveX + waveWidth,        waveY)
            local cp1 = imgui.ImVec2(waveX + waveWidth * 0.25, waveY - off)
            local cp2 = imgui.ImVec2(waveX + waveWidth * 0.75, waveY + off)
            local c   = isGlowPass and GetCol(1,1,1,1) or GetCol(theme.R,theme.G,theme.B,opacity)
            drawList:AddBezierCurve(p1, cp1, cp1, p2, c, 2.2)
            drawList:AddBezierCurve(p2, cp2, cp2, p3, c, 2.2)
        end
        drawWave(3.5, 0.2); drawWave(2.5, 0.4); drawWave(1.8, 0.6)
    end
end

imgui.OnFrame(
    function() return showWindow[0] or settingPosition or catchAnim.active or slideOutAnim.active or notifyAnim.active or notifyAnim.ending or notifyAnim2.active or notifyAnim2.ending end,
    function(self)
        self.HideCursor = not settingPosition

        -- обновляем t для flip-анимации (таймер + пинг)
        local dt = 1.0 / 60.0
        for i, cd in ipairs(tmr.flip) do
            if cd.t < 1.0 then cd.t = math.min(1.0, cd.t + dt * 8.0) end
        end
        for i, cd in ipairs(ping.flip) do
            if cd.t < 1.0 then cd.t = math.min(1.0, cd.t + dt * 8.0) end
        end

        if settingPosition then
            local cur = imgui.GetMousePos()
            window.x = cur.x - window.w / 2
            window.y = cur.y - 20
            if imgui.IsMouseClicked(0) then
                settingPosition = false
                if not active then showWindow[0] = false end
                saveSettings()
                loadMsg("Позиция окна сохранена!")
                if menu._reopenAfter then
                    menu._reopenAfter = false
                    openMenu()
                end
            end
        end

        local bgR, bgG, bgB, bgA = theme.bgR, theme.bgG, theme.bgB, 0.94
        if catchAnim.active then
            local elapsed = (os.clock() - catchAnim.startTime) * 1000
            if elapsed < 500 then
                -- фаза 1: фон без изменений
            elseif elapsed < 1500 then
                local t = (elapsed - 500) / 1000
                local ease = t * t * (3 - 2 * t)
                bgR = 0.06 + (0.0  - 0.06) * ease
                bgG = 0.06 + (0.78 - 0.06) * ease
                bgB = 0.06 + (0.28 - 0.06) * ease
                bgA = 0.94
            elseif elapsed < 2500 then
                local t = (elapsed - 1500) / 1000
                local alpha = 1.0 - t * t * (3 - 2 * t)
                bgR = 0.0
                bgG = 0.78
                bgB = 0.28
                bgA = 0.94 * alpha
            else
                catchAnim.active = false
                showWindow[0] = false
                imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.06, 0))
                imgui.SetNextWindowSize(imgui.ImVec2(window.w, window.h), imgui.Cond.Always)
                imgui.SetNextWindowPos(imgui.ImVec2(window.x, window.y), imgui.Cond.Always)
                imgui.Begin('##CatchWindow', showWindow, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
                imgui.PopStyleColor()
                imgui.End()
                return
            end
        end
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(bgR, bgG, bgB, bgA))

        local slideOffX, slideOffY = 0, 0
        if slideAnim.active then
            local elapsed = (os.clock() - slideAnim.startTime) * 1000
            if elapsed < slideAnim.duration then
                local t = elapsed / slideAnim.duration
                local ease = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
                slideOffX = slideAnim.offsetX * (1.0 - ease)
                slideOffY = slideAnim.offsetY * (1.0 - ease)
            else
                slideAnim.active = false
            end
        end
        if slideOutAnim.active then
            local elapsed = (os.clock() - slideOutAnim.startTime) * 1000
            if elapsed < slideOutAnim.duration then
                local t = elapsed / slideOutAnim.duration
                local ease = t * t * t
                slideOffX = slideOutAnim.offsetX * ease
                slideOffY = slideOutAnim.offsetY * ease
            else
                slideOutAnim.active = false
                showWindow[0] = false
                imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0,0,0,0))
                imgui.SetNextWindowSize(imgui.ImVec2(0, 0), imgui.Cond.Always)
                imgui.SetNextWindowPos(imgui.ImVec2(-9999, -9999), imgui.Cond.Always)
                imgui.Begin('##CatchWindow', showWindow, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
                imgui.PopStyleColor()
                imgui.End()
                return
            end
        end

        local prevMainRounding = imgui.GetStyle().WindowRounding
        imgui.GetStyle().WindowRounding = winCfg.cornerRadius
        imgui.SetNextWindowSize(imgui.ImVec2(window.w, window.h), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(window.x + slideOffX, window.y + slideOffY), imgui.Cond.Always)
        imgui.Begin('##CatchWindow', showWindow,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
        imgui.GetStyle().WindowRounding = prevMainRounding

        imgui.PopStyleColor()

        local drawList = imgui.GetWindowDrawList()
        local fgList   = imgui.GetForegroundDrawList()
        local pos      = imgui.GetWindowPos()
        local size     = imgui.GetWindowSize()
        local time     = os.clock()

        DrawContent(drawList, pos, time, false)
        local borderAlpha = 1.0
        if catchAnim.active then
            local elapsed = (os.clock() - catchAnim.startTime) * 1000
            if elapsed >= 1500 then
                local t = (elapsed - 1500) / 1000
                borderAlpha = 1.0 - t * t * (3 - 2 * t)
            end
        end
        DrawDashedBorder(fgList, pos, size, time, borderAlpha)

        local speed, beamWidth, tilt, pause = 250.0, 50.0, 25.0, 3.0
        local cycleTime = (size.x + beamWidth + tilt) / speed + pause
        local progress  = (time % cycleTime) * speed
        local beamStart = pos.x - beamWidth - tilt + progress

        if not catchAnim.active and beamStart < pos.x + size.x + beamWidth then
            for i = 1, 10 do
                local intensity = math.pow(math.sin((i / 10) * math.pi), 2) * 0.7
                local clipMin   = imgui.ImVec2(beamStart + (i-1)*(beamWidth/10), pos.y)
                local clipMax   = imgui.ImVec2(clipMin.x + (beamWidth/10) + tilt, pos.y + size.y)
                if clipMax.x > pos.x and clipMin.x < pos.x + size.x then
                    imgui.PushClipRect(clipMin, clipMax, true)
                    DrawContent(drawList, pos, time, true, intensity)
                    imgui.PopClipRect()
                end
            end
        end

        imgui.End()
    end
)

imgui.OnFrame(
    function() return notifyAnim.active end,
    function(self)
        self.HideCursor = true
        if notifyAnim.active then
            local elapsed = (os.clock() - notifyAnim.startTime) * 1000
            local totalDuration = 400 + 2000 + 400
            local slideH = 26
            local offsetY, alpha

            if notifyAnim.duration > 0 then
                if elapsed >= totalDuration then
                    notifyAnim.active = false
                    return
                end
                if elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = slideH * (1.0 - ease)
                    alpha = ease
                elseif elapsed < 2400 then
                    offsetY = 0
                    alpha = 1.0
                else
                    local t = (elapsed - 2400) / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = slideH * ease
                    alpha = 1.0 - ease
                end
            else
                if notifyAnim.ending then
                    local t = (os.clock() - notifyAnim.endTime) * 1000 / 400
                    if t >= 1.0 then
                        notifyAnim.active = false
                        notifyAnim.ending = false
                        return
                    end
                    local ease = t * t * (3 - 2 * t)
                    offsetY = 36 * ease
                    alpha = 1.0 - ease
                elseif elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = slideH * (1.0 - ease)
                    alpha = ease
                else
                    offsetY = 0
                    alpha = 1.0
                end
            end

            local winY = window.y - slideH - 3 + offsetY

            imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))
            imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))
            imgui.SetNextWindowPos(imgui.ImVec2(window.x, winY), imgui.Cond.Always)
            imgui.SetNextWindowSize(imgui.ImVec2(window.w, slideH), imgui.Cond.Always)
            imgui.Begin('##NotifyWindow', notifyAnim.winOpen,
                imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
                imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
                imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav +
                imgui.WindowFlags.NoBackground)
            imgui.PopStyleColor(2)

            local dl = imgui.GetWindowDrawList()
            local wpos = imgui.GetWindowPos()
            local activeFont = notifyAnim.useSmallFont and fonts.title or fonts.missed
            imgui.PushFont(activeFont)
            local txt = notifyAnim.text
            local textWidth = imgui.CalcTextSize(txt).x
            local textX = wpos.x + (window.w - textWidth) / 2
            local textY = winY + 4

            dl:PushClipRect(
                imgui.ImVec2(window.x - 10, window.y - slideH - 3),
                imgui.ImVec2(window.x + window.w + 10, window.y),
                false
            )
            dl:AddText(
                imgui.ImVec2(textX + 2, textY + 2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.6 * alpha)),
                txt
            )
            dl:AddText(
                imgui.ImVec2(textX, textY),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(notifyAnim.r, notifyAnim.g, notifyAnim.b, alpha)),
                txt
            )
            dl:PopClipRect()
            imgui.PopFont()
            imgui.End()
        end
    end
)



imgui.OnFrame(
    function() return notifyAnim2.active or notifyAnim2.ending end,
    function(self)
        self.HideCursor = true
        if notifyAnim2.active or notifyAnim2.ending then
            local elapsed = (os.clock() - notifyAnim2.startTime) * 1000
            local slideH = 26
            local offsetY, alpha

            if notifyAnim2.duration > 0 then
                local totalDuration = 400 + 2000 + 400
                if elapsed >= totalDuration then
                    notifyAnim2.active = false
                    return
                end
                if elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * (1.0 - ease)
                    alpha = ease
                elseif elapsed < 2400 then
                    offsetY = 0; alpha = 1.0
                else
                    local t = (elapsed - 2400) / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * ease
                    alpha = 1.0 - ease
                end
            else
                if notifyAnim2.ending then
                    local t = (os.clock() - notifyAnim2.endTime) * 1000 / 400
                    if t >= 1.0 then
                        notifyAnim2.active = false
                        notifyAnim2.ending = false
                        return
                    end
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * ease
                    alpha = 1.0 - ease
                elseif elapsed < 400 then
                    local t = elapsed / 400
                    local ease = t * t * (3 - 2 * t)
                    offsetY = -slideH * (1.0 - ease)
                    alpha = ease
                else
                    offsetY = 0; alpha = 1.0
                end
            end

            local winY = window.y + window.h + 3 + offsetY

            imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))
            imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))
            imgui.SetNextWindowPos(imgui.ImVec2(window.x, winY), imgui.Cond.Always)
            imgui.SetNextWindowSize(imgui.ImVec2(window.w, slideH), imgui.Cond.Always)
            imgui.Begin('##NotifyWindow2', notifyAnim2.winOpen,
                imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
                imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
                imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav +
                imgui.WindowFlags.NoBackground)
            imgui.PopStyleColor(2)

            local dl = imgui.GetWindowDrawList()
            local wpos = imgui.GetWindowPos()
            local activeFont = notifyAnim2.useSmallFont and fonts.title or fonts.missed
            imgui.PushFont(activeFont)
            local txt = notifyAnim2.text
            local textWidth = imgui.CalcTextSize(txt).x
            local textX = wpos.x + (window.w - textWidth) / 2
            local textY = window.y + window.h - 5 + offsetY

            dl:PushClipRect(
                imgui.ImVec2(window.x - 10, window.y + window.h),
                imgui.ImVec2(window.x + window.w + 10, window.y + window.h + slideH + 10),
                false
            )
            dl:AddText(
                imgui.ImVec2(textX + 2, textY + 2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.6 * alpha)),
                txt
            )
            dl:AddText(
                imgui.ImVec2(textX, textY),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(notifyAnim2.r, notifyAnim2.g, notifyAnim2.b, alpha)),
                txt
            )
            dl:PopClipRect()
            imgui.PopFont()
            imgui.End()
        end
    end
)

-- ===================== LOAD MENU FRAME =====================
imgui.OnFrame(
    function() return menu.win[0] end,
    function(self)
        self.HideCursor = false

        local sw, sh = getScreenResolution()
        local mw, mh = 340, 380
        local mx = (sw - mw) / 2
        local my = (sh - mh) / 2
        local now = os.clock()
        local elapsed = now - menu.stateTime

        -- Анимация
        if menu.state == "opening" then
            local t = math.min(elapsed / 0.32, 1.0)
            local ease = t * t * (3 - 2 * t)
            menu.alpha  = ease
            menu.slideY = (1.0 - ease) * 28
            if t >= 1.0 then menu.state = "open" end
        elseif menu.state == "open" then
            menu.alpha  = 1.0
            menu.slideY = 0.0
        elseif menu.state == "dismissing" then
            local t = math.min(elapsed / 0.25, 1.0)
            local ease = t * t * (3 - 2 * t)
            menu.alpha  = 1.0 - ease
            menu.slideY = ease * 22
            if t >= 1.0 then
                menu.win[0] = false
                menu.state  = "idle"
            end
        end

        local winY = my + menu.slideY

        imgui.GetStyle().WindowRounding = 14.0
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(
            theme.bgR + 0.02, theme.bgG + 0.02, theme.bgB + 0.02, 0.97 * menu.alpha))

        imgui.SetNextWindowSize(imgui.ImVec2(mw, mh), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(mx, winY), imgui.Cond.Always)

        imgui.Begin('##LoadMenuWindow', menu.win,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
            imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
            imgui.WindowFlags.NoScrollWithMouse)
        imgui.PopStyleColor()

        local dl   = imgui.GetWindowDrawList()
        local fgdl = imgui.GetForegroundDrawList()
        local pos  = imgui.GetWindowPos()
        local sz   = imgui.GetWindowSize()
        local t2   = now

        -- Рамка в стиле остальных окон
        DrawDashedBorder(fgdl, pos, sz, t2, menu.alpha)

        -- Кнопка закрытия
        local closeSize = 18
        local closeCX   = pos.x + mw - closeSize - 12
        local closeCY   = pos.y + 10
        local closeX2   = closeCX + closeSize
        local closeY2   = closeCY + closeSize
        local mpos = imgui.GetMousePos()
        local hoverClose = mpos.x >= closeCX and mpos.x <= closeX2 and
                           mpos.y >= closeCY and mpos.y <= closeY2
        local closeBgCol = hoverClose
            and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.9, 0.15, 0.15, menu.alpha))
            or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.5, 0.07, 0.07, 0.9 * menu.alpha))
        dl:AddRectFilled(imgui.ImVec2(closeCX, closeCY), imgui.ImVec2(closeX2, closeY2), closeBgCol, 5)
        dl:AddRect(imgui.ImVec2(closeCX, closeCY), imgui.ImVec2(closeX2, closeY2),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.35, 0.35, 0.35 * menu.alpha)), 5, 0, 1.0)
        local cpad = 5
        local ccol2 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, menu.alpha))
        dl:AddLine(imgui.ImVec2(closeCX+cpad, closeCY+cpad), imgui.ImVec2(closeX2-cpad, closeY2-cpad), ccol2, 1.8)
        dl:AddLine(imgui.ImVec2(closeX2-cpad, closeCY+cpad), imgui.ImVec2(closeCX+cpad, closeY2-cpad), ccol2, 1.8)
        if hoverClose and imgui.IsMouseClicked(0) and (menu.state == "open" or menu.state == "opening") then
            closeMenu()
        end

        -- Закрытие по ESC
        if escPressed() and (menu.state == "open" or menu.state == "opening") then
            closeMenu()
        end

        -- Заголовок
        imgui.PushFont(fonts.actTitle)
        local titleTxt = u8"Load Report"
        local titleW   = imgui.CalcTextSize(titleTxt).x
        dl:AddText(imgui.ImVec2(pos.x + (mw - titleW) / 2, pos.y + 13),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, menu.alpha)), titleTxt)
        imgui.PopFont()

        -- Версия
        imgui.PushFont(fonts.actSmall)
        local verTxt = "v" .. CURRENT_VERSION
        local verW   = imgui.CalcTextSize(verTxt).x
        dl:AddText(imgui.ImVec2(pos.x + (mw + titleW) / 2 + 5, pos.y + 18),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, 0.75 * menu.alpha)),
            verTxt)
        imgui.PopFont()

        -- Разделитель
        local sepY = pos.y + 42
        dl:AddLine(imgui.ImVec2(pos.x + 30, sepY), imgui.ImVec2(pos.x + mw - 30, sepY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, 0.35 * menu.alpha)), 1.0)
        dl:AddCircleFilled(imgui.ImVec2(pos.x + 26, sepY), 2.5,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, 0.55 * menu.alpha)), 8)
        dl:AddCircleFilled(imgui.ImVec2(pos.x + mw - 26, sepY), 2.5,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, 0.55 * menu.alpha)), 8)

        -- Кнопки
        local btnW, btnH, colGap, rowGap = 130, 62, 10, 8
        local gridTotalW = btnW * 2 + colGap
        local gridX = pos.x + (mw - gridTotalW) / 2
        local gridY = pos.y + 52

        if not menu.hoverT then menu.hoverT = {} end
        for i = 1, 5 do
            if not menu.hoverT[i] then menu.hoverT[i] = 0 end
        end

        local btnDefs = {
            { ix=0, iy=0, icon="pos",    label=u8"Позиция окна"   },
            { ix=1, iy=0, icon="key",    label=u8"Клавиша активации" },
            { ix=0, iy=1, icon="color",  label=u8"Выбрать цвет" },
            { ix=1, iy=1, icon="notify", label=notifyMinimizedEnabled and u8"Выкл. уведомления" or u8"Вкл. уведомления" },
            { ix=0, iy=2, icon="afk",    label=afkEnabled and u8"Выкл. авто-АФК" or u8"Вкл. авто-АФК" },
        }

        local canClick = (menu.state == "open" or menu.state == "opening")
        local hoverSpeed = 6.0

        for bi, b in ipairs(btnDefs) do
            local bx = gridX + b.ix * (btnW + colGap)
            local by = gridY + b.iy * (btnH + rowGap)
            local inBtn = mpos.x >= bx and mpos.x <= bx + btnW and mpos.y >= by and mpos.y <= by + btnH

            local dt2 = 1.0 / 60.0
            menu.hoverT[bi] = inBtn and math.min(1.0, menu.hoverT[bi] + dt2 * hoverSpeed) or math.max(0.0, menu.hoverT[bi] - dt2 * hoverSpeed)
            local ht = menu.hoverT[bi]
            local ease = ht * ht * (3 - 2 * ht)
            local iconAlpha = menu.alpha

            dl:AddRectFilled(imgui.ImVec2(bx+2, by+3), imgui.ImVec2(bx+btnW+2, by+btnH+3), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0,0,0, 0.38*menu.alpha)), 8)
            local bgA = 0.10 + ease * 0.12
            dl:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx+btnW, by+btnH), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, bgA*menu.alpha)), 8)
            local borderA = 0.30 + ease * 0.45
            dl:AddRect(imgui.ImVec2(bx, by), imgui.ImVec2(bx+btnW, by+btnH), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, borderA*menu.alpha)), 8, 0xF, 1.0)

            local cx, cy = bx + btnW/2, by + btnH/2
            local icol = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, iconAlpha))

            if b.icon == "pos" then
                local tex = getIconTexture("Map_Pin")
                if tex then
                    local sz = 24
                    local p0, p1 = iconDrawRect(tex, cx, cy, sz)
                    dl:AddImage(tex.tex, p0, p1, imgui.ImVec2(0,0), imgui.ImVec2(1,1), icol)
                else
                    -- Fallback: геометка (pin) от руки, пока картинка ещё не скачалась
                    local pinR    = 8
                    local pinTopCY = cy - 4
                    local pinTailY = cy + 11
                    dl:AddCircleFilled(imgui.ImVec2(cx, pinTopCY), pinR, icol, 24)
                    dl:AddTriangleFilled(
                        imgui.ImVec2(cx - pinR * 0.78, pinTopCY + pinR * 0.55),
                        imgui.ImVec2(cx + pinR * 0.78, pinTopCY + pinR * 0.55),
                        imgui.ImVec2(cx, pinTailY),
                        icol)
                    local holeCol = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.bgR + 0.02, theme.bgG + 0.02, theme.bgB + 0.02, 1.0))
                    dl:AddCircleFilled(imgui.ImVec2(cx, pinTopCY), pinR * 0.45, holeCol, 16)
                end

            elseif b.icon == "key" then
                local tex = getIconTexture("Keyboard")
                if tex then
                    local sz = 26
                    local p0, p1 = iconDrawRect(tex, cx, cy, sz)
                    dl:AddImage(tex.tex, p0, p1, imgui.ImVec2(0,0), imgui.ImVec2(1,1), icol)
                    -- Бейдж с текущей назначенной клавишей поверх иконки (сохраняем полезную инфу)
                    imgui.PushFont(fonts.actSmall)
                    local kTxt = getKeyName(cfg.key):sub(1,3)
                    local ts   = imgui.CalcTextSize(kTxt)
                    local badgeX = cx + sz/2 - ts.x/2 - 1
                    local badgeY = cy + sz/2 - ts.y/2 - 1
                    dl:AddRectFilled(imgui.ImVec2(badgeX-3, badgeY-1), imgui.ImVec2(badgeX+ts.x+3, badgeY+ts.y+1),
                        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.55*iconAlpha)), 4)
                    dl:AddText(imgui.ImVec2(badgeX, badgeY), icol, kTxt)
                    imgui.PopFont()
                else
                    -- Fallback: старый прямоугольник с текстом клавиши
                    local kw, kh = 34, 22
                    dl:AddRect(imgui.ImVec2(cx-kw/2, cy-kh/2), imgui.ImVec2(cx+kw/2, cy+kh/2), icol, 4, 0xF, 2.0)
                    imgui.PushFont(fonts.actSmall)
                    local kTxt = getKeyName(cfg.key):sub(1,3)
                    local ts = imgui.CalcTextSize(kTxt)
                    dl:AddText(imgui.ImVec2(cx - ts.x/2, cy - ts.y/2), icol, kTxt)
                    imgui.PopFont()
                end

            elseif b.icon == "color" then
                -- Прямоугольник цвета темы с белой рамкой (как окно)
                local rw, rh = 24, 17
                local rx, ry = cx - rw/2, cy - rh/2
                dl:AddRectFilled(
                    imgui.ImVec2(rx, ry), imgui.ImVec2(rx + rw, ry + rh),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, iconAlpha)), 4)
                dl:AddRect(
                    imgui.ImVec2(rx, ry), imgui.ImVec2(rx + rw, ry + rh),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, iconAlpha)), 4, 0xF, 1.5)

            elseif b.icon == "notify" then
                local tex = getIconTexture("Bell_Ring")
                if tex then
                    local sz = 24
                    -- слот для бейджа-статуса остаётся привязан к исходному квадрату sz,
                    -- а сама картинка рисуется пропорционально внутри него
                    local iconMinX, iconMinY = cx-sz/2, cy-sz/2
                    local iconMaxX, iconMaxY = cx+sz/2, cy+sz/2
                    local p0, p1 = iconDrawRect(tex, cx, cy, sz)
                    dl:AddImage(tex.tex, p0, p1, imgui.ImVec2(0,0), imgui.ImVec2(1,1), icol)
                    -- Точка статуса поверх иконки, как и раньше
                    local sOk = notifyMinimizedEnabled
                    local sc = sOk
                        and imgui.ImVec4(0.25, 0.95, 0.35, iconAlpha)
                        or  imgui.ImVec4(0.95, 0.25, 0.25, iconAlpha)
                    dl:AddCircleFilled(imgui.ImVec2(iconMaxX - 2, iconMinY + 2), 3.5, imgui.ColorConvertFloat4ToU32(sc), 8)
                else
                    -- Fallback: старый колокольчик от руки (по SVG notifications-none, viewBox 510x510)
                    local s = 22 / 510
                    local ox, oy = cx - 255*s, cy - 255*s

                    local bodyTopY = oy + 102*s
                    local bodyBotY = oy + 382.5*s
                    local bodyLX   = ox + 140.25*s
                    local bodyRX   = ox + 369.75*s
                    local apexX    = ox + 255*s
                    local apexY    = oy + 102*s

                    dl:AddBezierCurve(
                        imgui.ImVec2(apexX, apexY),
                        imgui.ImVec2(ox + 191*s, oy + 102*s),
                        imgui.ImVec2(bodyLX, oy + 150*s),
                        imgui.ImVec2(bodyLX, bodyBotY),
                        icol, 1.8, 16)
                    dl:AddBezierCurve(
                        imgui.ImVec2(apexX, apexY),
                        imgui.ImVec2(ox + 319*s, oy + 102*s),
                        imgui.ImVec2(bodyRX, oy + 150*s),
                        imgui.ImVec2(bodyRX, bodyBotY),
                        icol, 1.8, 16)

                    dl:AddLine(imgui.ImVec2(apexX, apexY), imgui.ImVec2(apexX, oy + 38*s), icol, 2.0)

                    dl:AddLine(imgui.ImVec2(ox + 89.25*s, oy + 408*s), imgui.ImVec2(ox + 420.75*s, oy + 408*s), icol, 2.0)
                    dl:AddLine(imgui.ImVec2(ox + 89.25*s, oy + 408*s), imgui.ImVec2(bodyLX, bodyBotY), icol, 1.6)
                    dl:AddLine(imgui.ImVec2(ox + 420.75*s, oy + 408*s), imgui.ImVec2(bodyRX, bodyBotY), icol, 1.6)

                    dl:AddCircleFilled(imgui.ImVec2(apexX, oy + 459*s), 8*s, icol, 14)

                    local sOk = notifyMinimizedEnabled
                    local sc = sOk
                        and imgui.ImVec4(0.25, 0.95, 0.35, iconAlpha)
                        or  imgui.ImVec4(0.95, 0.25, 0.25, iconAlpha)
                    dl:AddCircleFilled(imgui.ImVec2(bodyRX + 2, bodyTopY - 2), 3.5, imgui.ColorConvertFloat4ToU32(sc), 8)
                end

            elseif b.icon == "afk" then
                local tex = getIconTexture("Shuffle")
                if tex then
                    local sz = 24
                    local tintCol = afkEnabled
                        and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, iconAlpha))
                        or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.55, 0.55, 0.55, iconAlpha))
                    local p0, p1 = iconDrawRect(tex, cx, cy, sz)
                    dl:AddImage(tex.tex, p0, p1, imgui.ImVec2(0,0), imgui.ImVec2(1,1), tintCol)
                else
                    -- Fallback: старая фигурка человека + ZZZ
                    local s = 1.0
                    dl:AddCircle(imgui.ImVec2(cx, cy - 10*s), 5*s, icol, 14, 1.6)
                    dl:AddLine(imgui.ImVec2(cx, cy - 5*s), imgui.ImVec2(cx, cy + 3*s), icol, 1.8)
                    dl:AddLine(imgui.ImVec2(cx - 5*s, cy - 2*s), imgui.ImVec2(cx + 5*s, cy - 2*s), icol, 1.8)
                    dl:AddLine(imgui.ImVec2(cx, cy + 3*s), imgui.ImVec2(cx - 4*s, cy + 9*s), icol, 1.8)
                    dl:AddLine(imgui.ImVec2(cx, cy + 3*s), imgui.ImVec2(cx + 4*s, cy + 9*s), icol, 1.8)
                    local zx, zy = cx + 8*s, cy - 14*s
                    imgui.PushFont(fonts.actSmall)
                    local zcol = afkEnabled
                        and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, iconAlpha))
                        or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.5, 0.5, 0.5, iconAlpha))
                    dl:AddText(imgui.ImVec2(zx,        zy),        zcol, "z")
                    dl:AddText(imgui.ImVec2(zx + 6*s,  zy - 4*s),  zcol, "z")
                    dl:AddText(imgui.ImVec2(zx + 12*s, zy - 8*s),  zcol, "z")
                    imgui.PopFont()
                end
            end

            -- Подпись под иконкой
            imgui.PushFont(fonts.actSmall)
            local tw = imgui.CalcTextSize(b.label).x
            dl:AddText(imgui.ImVec2(cx - tw/2, by + btnH - 15),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.50 * menu.alpha)), b.label)
            imgui.PopFont()

            -- Обработка клика по кнопке
            if inBtn and imgui.IsMouseClicked(0) and canClick then
                if b.icon == "pos" then
                    menu._reopenAfter = true
                    closeMenu()
                    cmdSetPos()
                elseif b.icon == "key" then
                    menu._reopenAfter = true
                    closeMenu()
                    cmdSetKey()
                elseif b.icon == "color" then
                    menu._reopenAfter = true
                    closeMenu()
                    openColorPicker(menu._playerName or "")
                elseif b.icon == "notify" then
                    notifyMinimizedEnabled = not notifyMinimizedEnabled
                    saveSettings()
                    if notifyMinimizedEnabled then
                        loadMsg("Уведомление при свёрнутой игре {FFD700}включено.")
                    else
                        loadMsg("Уведомление при свёрнутой игре {FFD700}выключено.")
                    end
                elseif b.icon == "afk" then
                    afkEnabled = not afkEnabled
                    if not afkEnabled then afkActive = false end
                    saveSettings()
                    if afkEnabled then
                        loadMsg("Авто-АФК при активной ловле {FFD700}включено.")
                    else
                        loadMsg("Авто-АФК при активной ловле {FFD700}выключено.")
                    end
                end
            end
        end

        -- Кнопка подписки
        local subBtnW, subBtnH = gridTotalW, 42
        local subBtnX, subBtnY = gridX, gridY + 3 * (btnH + rowGap) + 8
        local inSubBtn = mpos.x >= subBtnX and mpos.x <= subBtnX + subBtnW and mpos.y >= subBtnY and mpos.y <= subBtnY + subBtnH
        local isChecking = (menu.subState == "checking")

        dl:AddRectFilled(imgui.ImVec2(subBtnX + 3, subBtnY + 4), imgui.ImVec2(subBtnX + subBtnW + 3, subBtnY + subBtnH + 4), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.32 * menu.alpha)), 10)
        local subBgR, subBgG, subBgB = theme.R * (inSubBtn and 0.85 or 0.55), theme.G * (inSubBtn and 0.85 or 0.55), theme.B * (inSubBtn and 0.85 or 0.55)
        if menu.subState == "done" then subBgR, subBgG, subBgB = menu.subIsOk and 0.08 or 0.42, menu.subIsOk and 0.42 or 0.08, menu.subIsOk and 0.08 or 0.08 end
        local subBgAlpha = isChecking and 0.6 or 1.0
        dl:AddRectFilled(imgui.ImVec2(subBtnX, subBtnY), imgui.ImVec2(subBtnX + subBtnW, subBtnY + subBtnH), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(subBgR, subBgG, subBgB, subBgAlpha * menu.alpha)), 8)
        dl:AddRect(imgui.ImVec2(subBtnX, subBtnY), imgui.ImVec2(subBtnX + subBtnW, subBtnY + subBtnH), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, (inSubBtn and 0.3 or 0.12) * menu.alpha)), 8, 0xF, 1.0)

        imgui.PushFont(fonts.actTitle)
        local subText = (menu.subState == "checking" and u8"Проверка...") or (menu.subState == "done" and menu.subMsg) or u8"Проверить подписку"
        local subTextW = imgui.CalcTextSize(subText).x
        local subTextH = imgui.CalcTextSize(subText).y
        dl:AddText(imgui.ImVec2(subBtnX + (subBtnW - subTextW) / 2, subBtnY + (subBtnH - subTextH) / 2), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.9 * menu.alpha)), subText)
        imgui.PopFont()

        -- Логика клика
        if inSubBtn and imgui.IsMouseClicked(0) and canClick and not isChecking then
            if menu.subState == "done" then menu.subState, menu.subMsg = "idle", ""
            else
                menu.subState = "checking"
                local t3 = whitelistThread(v103, menu._playerName or "")
                lua_thread.create(function()
                    local t0 = os.clock()
                    while true do
                        wait(200)
                        local s = t3:status()
                        if s == "completed" then
                            local ok2, r = pcall(function() return t3:get() end)
                            if ok2 and r and r.status == "success" then
                                menu.subIsOk = r.found
                                menu.subMsg = r.found and (r.expireTs and r.expireTs ~= 0 and os.date("*t", r.expireTs).day .. "." .. os.date("*t", r.expireTs).month .. "." .. os.date("*t", r.expireTs).year or u8"Активна (навсегда)") or u8"Подписка не найдена"
                            else menu.subIsOk, menu.subMsg = false, u8"Ошибка проверки" end
                            menu.subState = "done"; return
                        elseif s == "failed" then menu.subIsOk, menu.subMsg, menu.subState = false, u8"Ошибка сети", "done"; return
                        elseif os.clock() - t0 > 15 then menu.subIsOk, menu.subMsg, menu.subState = false, u8"Таймаут", "done"; return end
                    end
                end)
            end
        end

        imgui.End()
    end
)

-- ===================== SUBSCRIPTION ERROR WINDOW FRAME =====================
-- Открывается вместо остановки скрипта, когда воркер проверки подписки не
-- отвечает (таймаут / сетевая ошибка / неожиданный ответ). Дизайн повторяет
-- окно /loadmenu.
imgui.OnFrame(
    function() return subErr.win[0] end,
    function(self)
        self.HideCursor = false

        local sw, sh = getScreenResolution()
        local mw, mh = 340, 250
        local mx = (sw - mw) / 2
        local my = (sh - mh) / 2
        local now = os.clock()
        local elapsed = now - subErr.stateTime

        -- Анимация (1-в-1 как у /loadmenu)
        if subErr.state == "opening" then
            local t = math.min(elapsed / 0.32, 1.0)
            local ease = t * t * (3 - 2 * t)
            subErr.alpha  = ease
            subErr.slideY = (1.0 - ease) * 28
            if t >= 1.0 then subErr.state = "open" end
        elseif subErr.state == "open" then
            subErr.alpha  = 1.0
            subErr.slideY = 0.0
        elseif subErr.state == "dismissing" then
            local t = math.min(elapsed / 0.25, 1.0)
            local ease = t * t * (3 - 2 * t)
            subErr.alpha  = 1.0 - ease
            subErr.slideY = ease * 22
            if t >= 1.0 then
                subErr.win[0] = false
                subErr.state  = "idle"
            end
        end

        local winY = my + subErr.slideY

        imgui.GetStyle().WindowRounding = 14.0
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(
            theme.bgR + 0.02, theme.bgG + 0.02, theme.bgB + 0.02, 0.97 * subErr.alpha))

        imgui.SetNextWindowSize(imgui.ImVec2(mw, mh), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(mx, winY), imgui.Cond.Always)

        imgui.Begin('##SubErrWindow', subErr.win,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
            imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
            imgui.WindowFlags.NoScrollWithMouse)
        imgui.PopStyleColor()

        local dl   = imgui.GetWindowDrawList()
        local fgdl = imgui.GetForegroundDrawList()
        local pos  = imgui.GetWindowPos()
        local sz   = imgui.GetWindowSize()
        local t2   = now
        local mpos = imgui.GetMousePos()

        -- Рамка в стиле остальных окон
        DrawDashedBorder(fgdl, pos, sz, t2, subErr.alpha)

        -- Заголовок
        imgui.PushFont(fonts.actTitle)
        local titleTxt = u8"Load Report"
        local titleW   = imgui.CalcTextSize(titleTxt).x
        dl:AddText(imgui.ImVec2(pos.x + (mw - titleW) / 2, pos.y + 13),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, subErr.alpha)), titleTxt)
        imgui.PopFont()

        -- Разделитель
        local sepY = pos.y + 42
        dl:AddLine(imgui.ImVec2(pos.x + 30, sepY), imgui.ImVec2(pos.x + mw - 30, sepY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.35, 0.35, 0.35 * subErr.alpha)), 1.0)
        dl:AddCircleFilled(imgui.ImVec2(pos.x + 26, sepY), 2.5,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.35, 0.35, 0.55 * subErr.alpha)), 8)
        dl:AddCircleFilled(imgui.ImVec2(pos.x + mw - 26, sepY), 2.5,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.35, 0.35, 0.55 * subErr.alpha)), 8)

        -- Иконка предупреждения: картинка Wifi_Problem из icons.txt.
        -- Пока байты ещё не скачались/не распарсились — рисуем старый кружок с "!",
        -- чтобы окно не оставалось пустым.
        local iconCY = sepY + 44
        local iconCX = pos.x + mw / 2
        local wifiProblemTex = getIconTexture("Wifi_Problem")
        if wifiProblemTex then
            local iconSize = 64
            local p0, p1 = iconDrawRect(wifiProblemTex, iconCX, iconCY, iconSize)
            dl:AddImage(wifiProblemTex.tex, p0, p1,
                imgui.ImVec2(0, 0), imgui.ImVec2(1, 1),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, subErr.alpha)))
        else
            dl:AddCircleFilled(imgui.ImVec2(iconCX, iconCY), 28,
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.45, 0.10, 0.10, subErr.alpha)), 32)
            dl:AddCircle(imgui.ImVec2(iconCX, iconCY), 28,
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.35, 0.35, subErr.alpha)), 32, 2.2)
            imgui.PushFont(fonts.actTitle)
            local exTxt = "!"
            local exW   = imgui.CalcTextSize(exTxt).x
            local exH   = imgui.CalcTextSize(exTxt).y
            dl:AddText(imgui.ImVec2(iconCX - exW/2, iconCY - exH/2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.4, 0.4, subErr.alpha)), exTxt)
            imgui.PopFont()
        end

        -- Заголовок причины
        imgui.PushFont(fonts.actBody)
        local reasonTitle = u8"Не удалось проверить подписку"
        local rtW = imgui.CalcTextSize(reasonTitle).x
        dl:AddText(imgui.ImVec2(pos.x + (mw - rtW) / 2, iconCY + 44),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, subErr.alpha)), reasonTitle)
        imgui.PopFont()

        -- Текст причины (ручной перенос строк + центрирование, в стиле остальных окон)
        imgui.PushFont(fonts.actSmall)
        do
            local maxLineW = mw - 40
            local reasonText = subErr.reason or u8"Неизвестная ошибка"
            local lines = {}
            local curLine = ""
            for word in reasonText:gmatch("%S+") do
                local tryLine = (curLine == "") and word or (curLine .. " " .. word)
                if imgui.CalcTextSize(tryLine).x > maxLineW and curLine ~= "" then
                    lines[#lines + 1] = curLine
                    curLine = word
                else
                    curLine = tryLine
                end
            end
            if curLine ~= "" then lines[#lines + 1] = curLine end

            local lineH = imgui.CalcTextSize("A").y + 4
            local textY = iconCY + 66
            local reasonCol = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.75, 0.75, 0.75, subErr.alpha))
            for i, line in ipairs(lines) do
                local lw = imgui.CalcTextSize(line).x
                dl:AddText(imgui.ImVec2(pos.x + (mw - lw) / 2, textY + (i - 1) * lineH), reasonCol, line)
            end
        end
        imgui.PopFont()

        -- Кнопка "Повторить"
        local btnW, btnH = 200, 40
        local btnX = pos.x + (mw - btnW) / 2
        local btnY = pos.y + mh - btnH - 16
        local mInBtn = mpos.x >= btnX and mpos.x <= btnX + btnW and
                       mpos.y >= btnY and mpos.y <= btnY + btnH
        local isChecking = subErr.checking
        local canClick = (subErr.state == "open" or subErr.state == "opening")

        -- тень
        dl:AddRectFilled(imgui.ImVec2(btnX + 3, btnY + 5), imgui.ImVec2(btnX + btnW + 3, btnY + btnH + 5),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.3 * subErr.alpha)), 20)
        -- фон
        local btnBgAlpha = isChecking and 0.5 or 1.0
        local btnBgCol = (mInBtn and not isChecking)
            and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(math.min(theme.R + 0.15, 1), math.min(theme.G + 0.15, 1), math.min(theme.B + 0.15, 1), subErr.alpha))
            or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R * 0.9, theme.G * 0.9, theme.B * 0.9, subErr.alpha * btnBgAlpha))
        dl:AddRectFilled(imgui.ImVec2(btnX, btnY), imgui.ImVec2(btnX + btnW, btnY + btnH), btnBgCol, 20)
        dl:AddRectFilled(imgui.ImVec2(btnX + 14, btnY + btnH - 3), imgui.ImVec2(btnX + btnW - 14, btnY + btnH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.22 * subErr.alpha)), 3)

        imgui.PushFont(fonts.actBtn)
        local btnLabel = isChecking and u8"Проверка..." or u8"Повторить"
        local btnLabelW = imgui.CalcTextSize(btnLabel).x
        dl:AddText(imgui.ImVec2(btnX + (btnW - btnLabelW) / 2, btnY + (btnH - 17) / 2),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, subErr.alpha * btnBgAlpha)),
            btnLabel)
        imgui.PopFont()

        if mInBtn and imgui.IsMouseClicked(0) and canClick and not isChecking then
            subErr.checking       = true
            subErr.retryRequested = true
        end

        imgui.End()
    end
)
-- =============================================================================

-- ===================== COLOR PICKER WINDOW FRAME =====================
imgui.OnFrame(
    function() return cp.win[0] end,
    function(self)
        self.HideCursor = false

        local sw, sh = getScreenResolution()

        -- размеры окна пикера
        local cpW, cpH = 300, 520
        -- основное окно ловли (превью) располагаем по центру + вверху
        local previewW, previewH = window.w, window.h

        -- центр экрана
        local centerX = sw / 2
        local centerY = sh / 2

        -- окно ловли (превью) — прямо под пикером
        local previewX = centerX - previewW / 2
        -- пикер — над превью, с отступом 12px
        local cpX = centerX - cpW / 2
        local cpY = centerY - cpH / 2

        local now = os.clock()
        local elapsed = now - cp.stateTime

        -- анимация
        if cp.state == "opening" then
            local t = math.min(elapsed / 0.3, 1.0)
            local ease = t * t * (3 - 2 * t)
            cp.alpha  = ease
            cp.slideY = (1.0 - ease) * 28
            if t >= 1.0 then cp.state = "open" end
        elseif cp.state == "open" or cp.state == "saving" then
            cp.alpha  = 1.0
            cp.slideY = 0.0
        elseif cp.state == "dismissing" then
            local t = math.min(elapsed / 0.25, 1.0)
            cp.alpha  = 1.0 - t * t * (3 - 2 * t)
            cp.slideY = t * 22
            if t >= 1.0 then
                cp.win[0] = false
                cp.state = "idle"
                if menu._reopenAfter then
                    menu._reopenAfter = false
                    openMenu()
                end
            end
        end

        local winY = cpY + cp.slideY

        -- применяем превью live каждый кадр — все окна обновляются в реальном времени
        local pr, pg, pb = hsvToRgb(cp.hue, cp.sat, cp.val)
        local newHex = rgbToHex(pr, pg, pb)
        cp.previewHex = newHex
        applyThemeColor(newHex)

        -- ===== СНАЧАЛА РИСУЕМ ПРЕВЬЮ ОКНА ЛОВЛИ =====
        local previewY = winY + cpH + 12
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(theme.bgR, theme.bgG, theme.bgB, 0.94 * cp.alpha))
        imgui.SetNextWindowSize(imgui.ImVec2(previewW, previewH), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(previewX, previewY), imgui.Cond.Always)
        imgui.Begin('##CpPreviewWindow', cp.previewWinOpen,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
            imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
            imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav)
        imgui.PopStyleColor()

        local prevDL = imgui.GetWindowDrawList()
        local prevFG = imgui.GetForegroundDrawList()
        local prevPos = imgui.GetWindowPos()
        local prevSz  = imgui.GetWindowSize()
        DrawContent(prevDL, prevPos, now, false)
        DrawDashedBorder(prevFG, prevPos, prevSz, now, cp.alpha)
        imgui.End()

        -- ===== ОСНОВНОЕ ОКНО ПИКЕРА =====
        imgui.GetStyle().WindowRounding = 14.0
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(
            theme.bgR + 0.02, theme.bgG + 0.02, theme.bgB + 0.02, 0.97 * cp.alpha))

        imgui.SetNextWindowSize(imgui.ImVec2(cpW, cpH), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(cpX, winY), imgui.Cond.Always)

        imgui.Begin('##ColorPickerWindow', cp.win,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
            imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
            imgui.WindowFlags.NoScrollWithMouse)
        imgui.PopStyleColor()

        local dl   = imgui.GetWindowDrawList()
        local fgdl = imgui.GetForegroundDrawList()
        local pos  = imgui.GetWindowPos()
        local sz   = imgui.GetWindowSize()

        DrawDashedBorder(fgdl, pos, sz, now, cp.alpha)

        -- Кнопка закрытия
        local closeSize = 18
        local closeCX   = pos.x + cpW - closeSize - 12
        local closeCY   = pos.y + 10
        local closeX2   = closeCX + closeSize
        local closeY2   = closeCY + closeSize
        local mpos = imgui.GetMousePos()
        local hoverClose = mpos.x >= closeCX and mpos.x <= closeX2 and
                           mpos.y >= closeCY and mpos.y <= closeY2
        local closeBgCol = hoverClose
            and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.9, 0.15, 0.15, cp.alpha))
            or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.5, 0.07, 0.07, 0.9 * cp.alpha))
        dl:AddRectFilled(imgui.ImVec2(closeCX, closeCY), imgui.ImVec2(closeX2, closeY2), closeBgCol, 5)
        dl:AddRect(imgui.ImVec2(closeCX, closeCY), imgui.ImVec2(closeX2, closeY2),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.35, 0.35, 0.35 * cp.alpha)), 5, 0, 1.0)
        local pad = 5
        local ccol = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, cp.alpha))
        dl:AddLine(imgui.ImVec2(closeCX+pad, closeCY+pad), imgui.ImVec2(closeX2-pad, closeY2-pad), ccol, 1.8)
        dl:AddLine(imgui.ImVec2(closeX2-pad, closeCY+pad), imgui.ImVec2(closeCX+pad, closeY2-pad), ccol, 1.8)
        if hoverClose and imgui.IsMouseClicked(0) and (cp.state == "open" or cp.state == "opening") then
            -- откатываем к оригинальному цвету при закрытии без сохранения
            applyThemeColor(cp.originalColor)
            cp.state     = "dismissing"
            cp.stateTime = os.clock()
        end

        -- Закрытие по ESC
        if escPressed() and (cp.state == "open" or cp.state == "opening") then
            applyThemeColor(cp.originalColor)
            cp.state     = "dismissing"
            cp.stateTime = os.clock()
        end

        -- Заголовок
        imgui.PushFont(fonts.actTitle)
        local titleTxt = u8"Выбор цвета"
        local titleW   = imgui.CalcTextSize(titleTxt).x
        dl:AddText(imgui.ImVec2(pos.x + (cpW - titleW) / 2, pos.y + 12),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, cp.alpha)), titleTxt)
        imgui.PopFont()

        -- Разделитель
        local sepY = pos.y + 40
        dl:AddLine(imgui.ImVec2(pos.x + 30, sepY), imgui.ImVec2(pos.x + cpW - 30, sepY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, 0.35 * cp.alpha)), 1.0)

        -- =========== ЦВЕТОВОЕ КОЛЕСО (HUE WHEEL) ===========
        local wheelCX   = pos.x + cpW / 2
        local wheelCY   = pos.y + 172
        local wheelOuter = 100
        local wheelInner = 78
        local wheelSegs  = WHEEL_SEGS

        -- рисуем кольцо из треугольников для оттенков (геометрия/цвета из кэша)
        for i = 0, wheelSegs - 1 do
            local c0 = wheelCache[i]
            local c1 = wheelCache[i + 1]
            local col0 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(c0.r, c0.g, c0.b, cp.alpha))
            local col1 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(c1.r, c1.g, c1.b, cp.alpha))
            -- внешние точки
            local ox0 = wheelCX + c0.cosA * wheelOuter
            local oy0 = wheelCY + c0.sinA * wheelOuter
            local ox1 = wheelCX + c1.cosA * wheelOuter
            local oy1 = wheelCY + c1.sinA * wheelOuter
            -- внутренние точки
            local ix0 = wheelCX + c0.cosA * wheelInner
            local iy0 = wheelCY + c0.sinA * wheelInner
            local ix1 = wheelCX + c1.cosA * wheelInner
            local iy1 = wheelCY + c1.sinA * wheelInner
            -- два треугольника на сегмент
            dl:AddTriangleFilled(
                imgui.ImVec2(ox0, oy0), imgui.ImVec2(ox1, oy1), imgui.ImVec2(ix0, iy0),
                col0)
            dl:AddTriangleFilled(
                imgui.ImVec2(ox1, oy1), imgui.ImVec2(ix1, iy1), imgui.ImVec2(ix0, iy0),
                col1)
        end

        -- Маркер hue на колесе
        local hueAngle = cp.hue * math.pi * 2
        local hueMidR  = (wheelOuter + wheelInner) / 2
        local hmx = wheelCX + math.cos(hueAngle) * hueMidR
        local hmy = wheelCY + math.sin(hueAngle) * hueMidR
        dl:AddCircle(imgui.ImVec2(hmx, hmy), 9,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, cp.alpha)), 20, 2.5)
        dl:AddCircleFilled(imgui.ImVec2(hmx, hmy), 6,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(pr, pg, pb, cp.alpha)), 20)

        -- Drag hue wheel
        local inWheel = false
        do
            local dx = mpos.x - wheelCX
            local dy = mpos.y - wheelCY
            local dist = math.sqrt(dx*dx + dy*dy)
            inWheel = (dist >= wheelInner - 4 and dist <= wheelOuter + 4)
        end
        if imgui.IsMouseClicked(0) and inWheel and (cp.state == "open" or cp.state == "opening") then
            cp.draggingWheel = true
        end
        if cp.draggingWheel then
            if imgui.IsMouseDown(0) then
                local dx = mpos.x - wheelCX
                local dy = mpos.y - wheelCY
                local angle = math.atan2(dy, dx)
                cp.hue = (angle / (math.pi * 2)) % 1.0
                if cp.hue < 0 then cp.hue = cp.hue + 1.0 end
                cpSyncHexBuf()
            else
                cp.draggingWheel = false
            end
        end

        -- =========== SV КВАДРАТ (внутри колеса) ===========
        local svSize = (wheelInner - 8) * math.sqrt(2) / math.sqrt(2) * 0.78
        local svHalf = svSize / 2
        local svX    = wheelCX - svHalf
        local svY    = wheelCY - svHalf

        -- Рисуем SV квадрат через 4 corner цвета
        local hueR, hueG, hueB = hsvToRgb(cp.hue, 1, 1)
        local hueCol  = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(hueR, hueG, hueB, cp.alpha))
        local whiteCol= imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, cp.alpha))
        local blackCol= imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, cp.alpha))
        local transCol= imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0))

        -- горизонтальный градиент: белый -> цвет
        dl:AddRectFilledMultiColor(
            imgui.ImVec2(svX, svY),
            imgui.ImVec2(svX + svSize, svY + svSize),
            whiteCol, hueCol, hueCol, whiteCol)
        -- вертикальный градиент: прозрачный -> чёрный
        dl:AddRectFilledMultiColor(
            imgui.ImVec2(svX, svY),
            imgui.ImVec2(svX + svSize, svY + svSize),
            transCol, transCol, blackCol, blackCol)

        -- Маркер SV
        local svMarkerX = svX + cp.sat * svSize
        local svMarkerY = svY + (1.0 - cp.val) * svSize
        dl:AddCircle(imgui.ImVec2(svMarkerX, svMarkerY), 7,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, cp.alpha)), 20, 2.2)
        dl:AddCircleFilled(imgui.ImVec2(svMarkerX, svMarkerY), 4,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(pr, pg, pb, cp.alpha)), 20)

        -- Drag SV
        local inSV = mpos.x >= svX and mpos.x <= svX + svSize and
                     mpos.y >= svY and mpos.y <= svY + svSize
        if imgui.IsMouseClicked(0) and inSV and not cp.draggingWheel
           and (cp.state == "open" or cp.state == "opening") then
            cp.draggingSV = true
        end
        if cp.draggingSV then
            if imgui.IsMouseDown(0) then
                cp.sat = math.max(0, math.min(1, (mpos.x - svX) / svSize))
                cp.val = math.max(0, math.min(1, 1.0 - (mpos.y - svY) / svSize))
                cpSyncHexBuf()
            else
                cp.draggingSV = false
            end
        end

        -- =========== HEX INPUT ===========
        local hexAreaY  = pos.y + 290
        local hexLabelX = pos.x + 20
        local hexFieldW = cpW - 40
        local hexFieldH = 34

        imgui.PushFont(fonts.actSmall)
        dl:AddText(imgui.ImVec2(hexLabelX, hexAreaY),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.65, 0.65, 0.65, cp.alpha)),
            u8"HEX код:")
        imgui.PopFont()

        local fX = pos.x + 20
        local fY = hexAreaY + 20

        -- Preview цветной квадрат перед полем
        local previewSq = 26
        dl:AddRectFilled(imgui.ImVec2(fX, fY), imgui.ImVec2(fX + previewSq, fY + hexFieldH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(pr, pg, pb, cp.alpha)), 6)
        dl:AddRect(imgui.ImVec2(fX, fY), imgui.ImVec2(fX + previewSq, fY + hexFieldH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.2 * cp.alpha)), 6, 0, 1.0)

        -- Поле ввода hex
        local inputX = fX + previewSq + 6
        local inputW = hexFieldW - previewSq - 6

        dl:AddRectFilled(imgui.ImVec2(inputX, fY), imgui.ImVec2(inputX + inputW, fY + hexFieldH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.14, 0.14, 0.14, cp.alpha)), 6)
        dl:AddRect(imgui.ImVec2(inputX, fY), imgui.ImVec2(inputX + inputW, fY + hexFieldH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme.R, theme.G, theme.B, 0.4 * cp.alpha)), 6, 0, 1.0)

        imgui.SetCursorPos(imgui.ImVec2(inputX - pos.x + 8, fY - pos.y + (hexFieldH - 16) / 2))
        imgui.PushStyleColor(imgui.Col.FrameBg,        imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleColor(imgui.Col.FrameBgActive,  imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleColor(imgui.Col.Text,           imgui.ImVec4(1, 1, 1, cp.alpha))
        imgui.PushFont(fonts.actBody)
        imgui.PushItemWidth(inputW - 16)
        local hexEntered = imgui.InputText('##cphex', cp.hexBuf, 8,
            imgui.InputTextFlags.EnterReturnsTrue + imgui.InputTextFlags.CharsUppercase)
        imgui.PopItemWidth()
        imgui.PopFont()
        imgui.PopStyleColor(4)

        if hexEntered then
            local hexStr = ffi.string(cp.hexBuf):match("^%s*(.-)%s*$")
            if #hexStr == 6 then
                local tr, tg, tb = hexToRgb("#" .. hexStr)
                if tr then
                    cp.hue, cp.sat, cp.val = rgbToHsv(tr, tg, tb)
                    cpSyncHexBuf()
                end
            end
        end

        -- =========== RGB СЛАЙДЕРЫ ===========
        local sliderY   = fY + hexFieldH + 18
        local sliderW   = cpW - 40
        local sliderH   = 12
        local sliderX   = pos.x + 20
        local sliderGap = 26

        local function drawSlider(label, sx, sy, sw, sh2, value, r1, g1, b1, r2, g2, b2)
            -- трек
            dl:AddRectFilledMultiColor(
                imgui.ImVec2(sx, sy), imgui.ImVec2(sx + sw, sy + sh2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r1, g1, b1, cp.alpha)),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r2, g2, b2, cp.alpha)),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r2, g2, b2, cp.alpha)),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r1, g1, b1, cp.alpha)))
            dl:AddRect(imgui.ImVec2(sx, sy), imgui.ImVec2(sx + sw, sy + sh2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.12 * cp.alpha)), 4, 0, 1.0)
            -- ручка
            local kx = sx + value * sw
            local ky = sy + sh2 / 2
            dl:AddCircleFilled(imgui.ImVec2(kx, ky), sh2 * 0.85,
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, cp.alpha)), 16)
            dl:AddCircle(imgui.ImVec2(kx, ky), sh2 * 0.85,
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.4 * cp.alpha)), 16, 1.2)
            -- лейбл
            imgui.PushFont(fonts.actSmall)
            dl:AddText(imgui.ImVec2(sx + sw + 8, sy - 2),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.7, 0.7, 0.7, cp.alpha)),
                label .. ": " .. math.floor(value * 255 + 0.5))
            imgui.PopFont()
        end

        drawSlider("R", sliderX, sliderY,              sliderW - 55, sliderH, pr, 0, pg, pb, 1, pg, pb)
        drawSlider("G", sliderX, sliderY + sliderGap,  sliderW - 55, sliderH, pg, pr, 0, pb, pr, 1, pb)
        drawSlider("B", sliderX, sliderY + sliderGap*2,sliderW - 55, sliderH, pb, pr, pg, 0, pr, pg, 1)

        -- drag слайдеров
        local sliders = {
            { y = sliderY,              comp = "R" },
            { y = sliderY + sliderGap,  comp = "G" },
            { y = sliderY + sliderGap*2,comp = "B" },
        }
        for _, sl in ipairs(sliders) do
            local inSlider = mpos.x >= sliderX and mpos.x <= sliderX + sliderW - 55 and
                             mpos.y >= sl.y - 6 and mpos.y <= sl.y + sliderH + 6
            if imgui.IsMouseDown(0) and inSlider
               and not cp.draggingWheel and not cp.draggingSV
               and (cp.state == "open" or cp.state == "opening") then
                local newVal = math.max(0, math.min(1, (mpos.x - sliderX) / (sliderW - 55)))
                local cr, cg, cb = hsvToRgb(cp.hue, cp.sat, cp.val)
                if     sl.comp == "R" then cr = newVal
                elseif sl.comp == "G" then cg = newVal
                else                       cb = newVal end
                cp.hue, cp.sat, cp.val = rgbToHsv(cr, cg, cb)
                cpSyncHexBuf()
            end
        end

        -- =========== СТАТУС ===========
        if cp.saveStatus ~= "" then
            imgui.PushFont(fonts.actSmall)
            local msgW2 = imgui.CalcTextSize(cp.saveStatus).x
            local mr2 = cp.saveIsErr and 1.0 or 0.3
            local mg2 = cp.saveIsErr and 0.3 or 1.0
            local mb2 = cp.saveIsErr and 0.3 or 0.4
            dl:AddText(imgui.ImVec2(pos.x + (cpW - msgW2) / 2, sliderY + sliderGap * 3 + 4),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(mr2, mg2, mb2, cp.alpha)),
                cp.saveStatus)
            imgui.PopFont()
        end

        -- =========== КНОПКА СОХРАНИТЬ ===========
        local saveBtnW, saveBtnH = 200, 40
        local saveBtnX = pos.x + (cpW - saveBtnW) / 2
        local saveBtnY = pos.y + cpH - saveBtnH - 16
        local isSaving = (cp.state == "saving")
        local mInSave  = mpos.x >= saveBtnX and mpos.x <= saveBtnX + saveBtnW and
                         mpos.y >= saveBtnY and mpos.y <= saveBtnY + saveBtnH

        -- тень
        dl:AddRectFilled(imgui.ImVec2(saveBtnX + 3, saveBtnY + 5),
            imgui.ImVec2(saveBtnX + saveBtnW + 3, saveBtnY + saveBtnH + 5),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.3 * cp.alpha)), 20)
        -- фон
        local saveBgAlpha = isSaving and 0.5 or 1.0
        local saveBgCol = (mInSave and not isSaving)
            and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
                math.min(theme.R + 0.15, 1), math.min(theme.G + 0.15, 1), math.min(theme.B + 0.15, 1), cp.alpha))
            or  imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
                theme.R * 0.9, theme.G * 0.9, theme.B * 0.9, cp.alpha * saveBgAlpha))
        dl:AddRectFilled(imgui.ImVec2(saveBtnX, saveBtnY),
            imgui.ImVec2(saveBtnX + saveBtnW, saveBtnY + saveBtnH), saveBgCol, 20)
        dl:AddRectFilled(imgui.ImVec2(saveBtnX + 14, saveBtnY + saveBtnH - 3),
            imgui.ImVec2(saveBtnX + saveBtnW - 14, saveBtnY + saveBtnH),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.22 * cp.alpha)), 3)
        -- текст кнопки
        imgui.PushFont(fonts.actBtn)
        local saveLabel = isSaving and u8"Сохранение..." or u8"Сохранить"
        local saveLabelW = imgui.CalcTextSize(saveLabel).x
        dl:AddText(imgui.ImVec2(saveBtnX + (saveBtnW - saveLabelW) / 2, saveBtnY + (saveBtnH - 17) / 2),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, cp.alpha * saveBgAlpha)),
            saveLabel)
        imgui.PopFont()

        -- Клик «Сохранить»
        if mInSave and imgui.IsMouseClicked(0) and not isSaving and not cp.saveActive
           and (cp.state == "open" or cp.state == "opening") then
            local colorHex  = cp.previewHex
            local savingFor = cp -- захватываем ссылку сессии на момент клика
            local mySession = cp.session
            local nick      = cp.playerName
            cp.state      = "saving"
            cp.saveActive = true
            cp.saveStatus = u8"Сохраняем..."
            cp.saveIsErr  = false

            -- Та же схема, что у проверки подписки при старте скрипта (runWhitelistCheck):
            -- один lua_thread.create + pcall(блокирующий синхронный хелпер, ...).
            -- Без callback-параметра и без вложенного lua_thread внутри хелпера.
            lua_thread.create(function()
                local ok, r = pcall(runColorChangeSync, nick, colorHex)
                if not ok or not r then r = { status = 0, error = "request_failed" } end

                -- устаревший ответ (пикер закрыт/переоткрыт заново, пока шёл запрос) — игнорируем
                if savingFor.session ~= mySession then return end
                savingFor.saveActive = false
                if not savingFor.win[0] then return end
                savingFor.state = "open"

                if r.status == 200 then
                    -- обновляем оригинал — теперь новый цвет считается "сохранённым"
                    savingFor.originalColor = colorHex
                    applyThemeColor(colorHex)
                    savingFor.saveStatus = u8"Цвет сохранён!"
                    savingFor.saveIsErr  = false
                    loadMsg("Цвет сохранён: {FFD700}" .. colorHex)
                    wait(1800)
                    -- за время ожидания могла начаться новая сессия пикера — не трогаем её
                    if savingFor.session == mySession then
                        savingFor.state     = "dismissing"
                        savingFor.stateTime = os.clock()
                    end
                elseif r.status == 429 then
                    savingFor.saveStatus = u8"Кулдаун: " .. (r.retry_after or "?") .. " сек."
                    savingFor.saveIsErr  = true
                    -- откат к оригиналу
                    applyThemeColor(savingFor.originalColor)
                elseif r.error == "no_subscription" then
                    savingFor.saveStatus = u8"Подписка не найдена"
                    savingFor.saveIsErr  = true
                    applyThemeColor(savingFor.originalColor)
                else
                    savingFor.saveStatus = u8"Ошибка, попробуйте позже"
                    savingFor.saveIsErr  = true
                    applyThemeColor(savingFor.originalColor)
                end
            end)
        end

        imgui.End()
    end
)
-- ===================================================================

local SETTINGS_FILE        = getWorkingDirectory() .. "\\load_settings.ini"
-- Замените на реальный URL, где лежит window_editor.html (например, тот же репозиторий,
-- откуда качаются звуки/шрифт). Если файл уже лежит рядом со скриптом — скачивание пропускается.
local LEGACY_SETTINGS_FILE = getWorkingDirectory() .. "\\spam_settings.ini"
local firstLaunch = true

local function isReportCaught()
    local ok, val = pcall(function() return _G["var_0_77"] end)
    if ok and type(val) == "table" then return val.ok ~= nil end
    return false
end

local function isReportWindowOpen()
    local ok, val = pcall(function() return _G["win"] end)
    if ok and type(val) == "table" and val.report then return val.report.v == true end
    return false
end

local function doUpdate()
    loadMsg("Скачиваю новую версию...")

    -- Пути старого и нового файла
    local oldPath = thisScript().path
    local newPath = oldPath
    if not newPath:find("%.luac$") then
        newPath = newPath:gsub("%.lua$", ".luac")
    end

    -- Удаляем старый файл перед скачиванием
    if doesFileExist(oldPath) then
        os.remove(oldPath)
    end
    if oldPath ~= newPath and doesFileExist(newPath) then
        os.remove(newPath)
    end

    local dlstatus = require('moonloader').download_status
    local done   = false
    local failed = false
    downloadUrlToFile(LUAC_URL, newPath, function(id, status, p1, p2)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            done = true
        elseif status == dlstatus.STATUS_DOWNLOADFAILED then
            failed = true
            done   = true
        end
    end)
    local t0 = os.clock()
    while not done do
        wait(200)
        if os.clock() - t0 > 30 then
            loadMsg("Таймаут загрузки!")
            return
        end
    end
    if failed then
        loadMsg("Ошибка при скачивании файла!")
        return
    end
    loadMsg("Обновление установлено! Перезагрузка...")
    wait(1500)
    thisScript():reload()
end

local function startVersionChecker()
    lua_thread.create(function()
        while true do
            local t = versionCheckThread()
            local t0 = os.clock()
            local timedOut = false
            while true do
                wait(300)
                local s = t:status()
                if s == "completed" or s == "failed" then break end
                if os.clock() - t0 > 15 then
                    timedOut = true
                    break
                end
            end
            if not timedOut and t:status() == "completed" then
                local ok2, r = pcall(function() return t:get() end)
                if ok2 and r and not r.error and r.version then
                    if r.version ~= CURRENT_VERSION then
                        loadMsg("Доступна новая версия: " .. r.version .. "! Скачиваю автоматически...")
                        lua_thread.create(doUpdate)
                        return
                    end
                end
            end
            wait(180000)
        end
    end)
end

local function triggerCatchAnimation()
    catchAnim.active = true
    catchAnim.startTime = os.clock()
    notifyAnim.active = false
    notifyAnim.ending = false
    notifyAnim2.active = false
    notifyAnim2.ending = false
    showWindow[0] = true
    playSound(sounds.caught)
end

local function triggerSlideAnim()
    local sw, sh = getScreenResolution()
    local dLeft   = window.x
    local dRight  = sw - (window.x + window.w)
    local dTop    = window.y
    local dBottom = sh - (window.y + window.h)
    local minD = math.min(dLeft, dRight, dTop, dBottom)
    local ox, oy = 0, 0
    if minD == dLeft then
        ox = -(window.w + 20)
    elseif minD == dRight then
        ox = (window.w + 20)
    elseif minD == dTop then
        oy = -(window.h + 20)
    else
        oy = (window.h + 20)
    end
    slideAnim.active    = true
    slideAnim.startTime = os.clock()
    slideAnim.offsetX   = ox
    slideAnim.offsetY   = oy
end

local function triggerSlideOutAnim()
    local sw, sh = getScreenResolution()
    local dLeft   = window.x
    local dRight  = sw - (window.x + window.w)
    local dTop    = window.y
    local dBottom = sh - (window.y + window.h)
    local minD = math.min(dLeft, dRight, dTop, dBottom)
    local ox, oy = 0, 0
    if minD == dLeft then
        ox = -(window.w + 20)
    elseif minD == dRight then
        ox = (window.w + 20)
    elseif minD == dTop then
        oy = -(window.h + 20)
    else
        oy = (window.h + 20)
    end
    slideOutAnim.active    = true
    slideOutAnim.startTime = os.clock()
    slideOutAnim.offsetX   = ox
    slideOutAnim.offsetY   = oy
end

function sampev.onShowDialog(id, type, title, button1, button2, text)
    if id == 1334 and active then
        active = false
        st.caughtDelta = st.caughtDelta + 1
        if spamThread then spamThread.status = "dead"; spamThread = nil end
        loadMsg("Репорт {FFD700}пойман! {FFFFFF}Ловля остановлена.")
        notifyIfMinimized()
        triggerCatchAnimation()
    end
end

-- ===================== AUTO-AFK =====================
function onSendPacket()
    if afkActive then
        return false
    end
end
-- =====================================================

function main()

    print(("[DBG %.2f] main(): СТАРТ"):format(os.clock()))

    if not isSampLoaded() or not isSampfuncsLoaded() then
        print(("[DBG %.2f] main(): SAMP ещё не загружен, ждём isSampAvailable()"):format(os.clock()))
        while not isSampAvailable() do wait(100) end
        print(("[DBG %.2f] main(): SAMP стал доступен"):format(os.clock()))
    end

    print(("[DBG %.2f] main(): вызов updateScript()"):format(os.clock()))
    updateScript()

    print(("[DBG %.2f] main(): wait(3000) - пауза 3 сек"):format(os.clock()))
    wait(3000)
    print(("[DBG %.2f] main(): ждём isSampAvailable()"):format(os.clock()))
    while not isSampAvailable() do wait(100) end
    print(("[DBG %.2f] main(): ждём sampIsLocalPlayerSpawned()"):format(os.clock()))
    while not sampIsLocalPlayerSpawned() do wait(100) end
    print(("[DBG %.2f] main(): игрок заспавнен, wait(500)"):format(os.clock()))
    wait(500)

    -- ===== ПЕРЕХВАТ ESC: блокируем открытие меню паузы когда открыты наши окна =====
    -- Используем PostMessageA(WM_KEYUP) чтобы немедленно "отпустить" ESC для игры
    local WM_KEYUP   = 0x0101
    local WM_KEYDOWN = 0x0100
    lua_thread.create(function()
        while true do
            wait(0)
            -- GetAsyncKeyState реагирует быстрее чем isKeyDown
            local ks = ffi.C.GetAsyncKeyState(0x1B)
            if bit.band(ks, 0x8000) ~= 0 then
                local anyOpen = menu.win[0] or cp.win[0] or subErr.win[0]
                if anyOpen then
                    escConsumed = true
                    -- Находим окно игры и посылаем WM_KEYUP чтобы SAMP думал что ESC уже отпущен
                    local gameWnd = ffi.C.FindWindowA("SAMP", nil)
                    if gameWnd == nil or gameWnd == ffi.cast("void*", 0) then
                        gameWnd = ffi.C.FindWindowA(nil, "Arizona RP")
                    end
                    if gameWnd ~= nil and gameWnd ~= ffi.cast("void*", 0) then
                        ffi.C.PostMessageA(gameWnd, WM_KEYUP, 0x1B, 0)
                    end
                    while bit.band(ffi.C.GetAsyncKeyState(0x1B), 0x8000) ~= 0 do wait(0) end
                end
            end
        end
    end)
    -- ============================================================================

    -- ===== СКАЧИВАНИЕ ИКОНОК (в фоне, не блокируя) =====
    -- Запускаем максимально рано: окно "не удалось проверить подписку" может
    -- появиться уже через несколько секунд (если сервер не ответил), и к этому
    -- моменту иконка Wifi_Problem, скорее всего, уже успеет скачаться.
    lua_thread.create(function() ensureIcons() end)

    -- ===== СКАЧИВАНИЕ ШРИФТА =====
    print(("[DBG %.2f] main(): проверка ESC-хука установлена, переходим к шрифту"):format(os.clock()))
    ensureSoundDir()
    if not doesFileExist(FONT_PATH) then
        print(("[DBG %.2f] main(): файл шрифта ОТСУТСТВУЕТ, начинаем скачивание с %s"):format(os.clock(), FONT_URL))
        local dlstatus = require('moonloader').download_status
        local fontDone = false

        downloadUrlToFile(FONT_URL, FONT_PATH, function(id, status)
            print(("[DBG %.2f] main(): callback скачивания шрифта, status=%s"):format(os.clock(), tostring(status)))
            if status == dlstatus.STATUS_ENDDOWNLOADDATA then
                fontDone = true
            end
        end)
        local t = os.clock()
        while not fontDone and os.clock() - t < 10 do
            wait(100)
        end
        if fontDone then
            print(("[DBG %.2f] main(): шрифт скачан за %.2f сек"):format(os.clock(), os.clock()-t))
        else
            print(("[DBG %.2f] main(): ТАЙМАУТ скачивания шрифта (10 сек истекло, fontDone=false)"):format(os.clock()))
        end
        if doesFileExist(FONT_PATH) then
            print(("[DBG %.2f] main(): файл шрифта существует на диске -> RELOAD скрипта"):format(os.clock()))
            wait(500)
            thisScript():reload()
            return
        else
            print(("[DBG %.2f] main(): файл шрифта так и НЕ появился на диске, продолжаем без релоада"):format(os.clock()))
        end
    else
        print(("[DBG %.2f] main(): файл шрифта уже есть, скачивание не требуется"):format(os.clock()))
    end
    -- ======================================================

    local myId = select(2, sampGetPlayerIdByCharHandle(playerPed))
    local playerName = sampGetPlayerNickname(myId)
    print(("[DBG %.2f] main(): playerName=%s"):format(os.clock(), tostring(playerName)))

    -- Загрузка звуков в фоне
    print(("[DBG %.2f] main(): запуск initSounds() в фоновом потоке"):format(os.clock()))
    lua_thread.create(function()
        initSounds()
        print(("[DBG %.2f] initSounds(): фоновая загрузка звуков запущена/завершена"):format(os.clock()))
    end)

    -- ===== ОБНОВЛЕНИЕ ПИНГА каждые 2 секунды =====
    lua_thread.create(function()
        while true do
            updatePing()
            if ping.val > 0 then
                st.pingSum     = st.pingSum + ping.val
                st.pingSamples = st.pingSamples + 1
            end
            wait(2000)
        end
    end)

    -- ===== ЗАЩИТА: контроль ответа сервера на /ot =====
    lua_thread.create(function()
        -- ждём включения ловли
        print(("[DBG %.2f] защита-поток: ждём active=true"):format(os.clock()))
        while not active do wait(100) end
        print(("[DBG %.2f] защита-поток: active=true, начинаем мониторинг 2 сек"):format(os.clock()))

        -- запоминаем время включения и сбрасываем таймер
        local activationTime = os.clock()
        lastNoQuestionsTime = os.clock()

        -- мониторим только первые 2 секунды
        wait(2000)

        -- если за эти 2 секунды не было ни одного сообщения — защита
        if active and not protectionActive then
            if lastNoQuestionsTime <= activationTime then
                print(("[DBG %.2f] защита-поток: СРАБОТАЛА ЗАЩИТА - сервер не ответил за 2 сек, ловля ОСТАНОВЛЕНА (нужен Ctrl+R)"):format(os.clock()))
                protectionActive = true
                active = false

                if spamThread then spamThread.status = "dead"; spamThread = nil end
                catchAnim.active = false
                triggerSlideOutAnim()
                playSound(sounds.disable)
                showNotify(u8"Защита: нажмите Ctrl+R", 1.0, 0.25, 0.25, 0, false)
                loadMsg("Извините, но мы были вынуждены приостановить ловлю! :pained:")
                loadMsg("Это нужно для корректной работы всех функций! :u1f60e:")
                loadMsg("Нажмите {FFD700}Ctrl+R {FFFFFF}и продолжайте ловлю!")
            end
        end
        -- поток завершается — больше не проверяет до перезапуска скрипта
    end)

    -- Запускаем проверку whitelist (с возможностью повторной попытки при ошибке сервера)
    print(("[DBG %.2f] main(): запуск проверки whitelist (подписки)"):format(os.clock()))

    local wlResultKind = nil   -- "found" / "not_found" / "error"
    local wlErrorReason = ""

    local function startWhitelistAttempt()
        local wlDone = false
        lua_thread.create(function()
            local ok, res = pcall(runWhitelistCheck, playerName)
            print(("[DBG %.2f] main(): whitelist-поток вернул ok=%s res=%s"):format(os.clock(), tostring(ok), tostring(res)))
            if not ok or not res then
                wlResultKind  = "error"
                wlErrorReason = u8"Сервер проверки подписки не ответил (таймаут соединения)."
            elseif res.status == "error" then
                wlResultKind  = "error"
                wlErrorReason = u8"Сервер вернул ошибку (код: " .. tostring(res.code or "?") .. ")."
            elseif res.status == "success" then
                if res.found then
                    wlResultKind    = "found"
                    hasSubscription = true
                    subExpireTs     = res.expireTs or 0
                    if res.color then applyThemeColor(res.color) end
                    print(("[DBG %.2f] main(): hasSubscription=TRUE, expireTs=%s"):format(os.clock(), tostring(subExpireTs)))
                else
                    wlResultKind = "not_found"
                    print(("[DBG %.2f] main(): подписка не найдена"):format(os.clock()))
                end
            else
                wlResultKind  = "error"
                wlErrorReason = u8"Неожиданный ответ сервера."
            end
            wlDone = true
        end)
        local wlTimeout = os.clock() + 15
        while not wlDone and os.clock() < wlTimeout do wait(100) end
        if not wlDone then
            wlResultKind  = "error"
            wlErrorReason = u8"Превышено время ожидания ответа сервера (15 сек)."
            print(("[DBG %.2f] main(): ТАЙМАУТ ожидания whitelist (15 сек истекло!)"):format(os.clock()))
        end
    end

    while true do
        startWhitelistAttempt()

        if wlResultKind == "found" then
            if subErr.win[0] then closeSubErrWindow() end
            break

        elseif wlResultKind == "not_found" then
            -- Подписка реально не найдена/истекла — сообщаем в чат и завершаем скрипт
            if subErr.win[0] then closeSubErrWindow() end
            print(("[DBG %.2f] main(): НЕТ ПОДПИСКИ -> выводим ошибку и терминируем скрипт"):format(os.clock()))
            sampAddChatMessage("{FF3333}[Load:zap:Report]:right: {FFFFFF}Подписка не найдена или истекла!", 0xFF3333)
            sampAddChatMessage("{FF3333}[Load:zap:Report]:right: {FFFFFF}Функционал скрипта недоступен без активной подписки.", 0xFF3333)
            thisScript():unload()
            return

        else -- "error" — сервер недоступен/ошибка/таймаут: не крашимся, даём повторить
            print(("[DBG %.2f] main(): ОШИБКА СЕРВЕРА (%s) -> открываем окно с кнопкой Повторить"):format(os.clock(), tostring(wlErrorReason)))
            if not subErr.win[0] then
                openSubErrWindow(wlErrorReason)
            else
                subErr.reason   = wlErrorReason
                subErr.checking = false
            end
            -- ждём, пока пользователь нажмёт "Повторить"
            while not subErr.retryRequested do wait(100) end
            subErr.retryRequested = false
            -- цикл повторит startWhitelistAttempt()
        end
    end

    -- Переносим данные из старых отдельных файлов (spam_settings.ini, vk_review.ini)
    -- в единый файл настроек, после чего старые файлы удаляются.
    print(("[DBG %.2f] main(): migrateLegacySettings()"):format(os.clock()))
    migrateLegacySettings()
    print(("[DBG %.2f] main(): loadSettings()"):format(os.clock()))
    loadSettings()
    print(("[DBG %.2f] main(): настройки загружены, идём дальше"):format(os.clock()))

    print(("[DBG %.2f] main(): firstLaunch=%s"):format(os.clock(), tostring(firstLaunch)))
    if firstLaunch then
        loadMsg("Первый запуск! Сменить клавишу: {FFD700}/loadkey {FFFFFF}| сменить позицию: {FFD700}/loadpos")
    end
    saveSettings()  -- чтобы записать FIRST_LAUNCH=false
    print(("[DBG %.2f] main(): saveSettings() выполнен"):format(os.clock()))

    do
        local keyLabel = getKeyName(cfg.key)
        local subPart = ""
        if subExpireTs ~= 0 then
            local t2 = os.date("*t", subExpireTs)
            subPart = string.format("Подписка действует: {FFD700}%02d.%02d.%04d {FFFFFF}| ", t2.day, t2.month, t2.year)
        end
        loadMsg(subPart .. "Клавиша активации: {FFD700}" .. keyLabel .. " ")
        loadMsg(subPart .. "Меню настроек: {FFD700}/loadmenu")

        announceCurrentVersion()
    end

    print(("[DBG %.2f] main(): startVersionChecker()"):format(os.clock()))
    startVersionChecker()
    print(("[DBG %.2f] main(): регистрация чат-команд..."):format(os.clock()))

    sampRegisterChatCommand("loadsite", function()
        loadMsg("Открываем сайт в браузере...")
        os.execute('start "" "' .. SITE_URL .. '"')
    end)

    sampRegisterChatCommand("setpos", function()
        cmdSetPos()
    end)

    sampRegisterChatCommand("setkey", function()
        cmdSetKey()
    end)

    sampRegisterChatCommand("loadnotify", function()
        notifyMinimizedEnabled = not notifyMinimizedEnabled
        saveSettings()
        if notifyMinimizedEnabled then
            loadMsg("Уведомление при свёрнутой игре {FFD700}включено.")
        else
            loadMsg("Уведомление при свёрнутой игре {FFD700}выключено.")
        end
    end)

    sampRegisterChatCommand("loadcolor", function()
        openColorPicker(playerName)
    end)

    sampRegisterChatCommand("loadmenu", function()
        menu._playerName = playerName
        openMenu()
    end)

    sampRegisterChatCommand("loadafk", function()
        afkEnabled = not afkEnabled
        if not afkEnabled then
            afkActive = false
        end
        saveSettings()
        if afkEnabled then
            loadMsg("Авто-АФК при активной ловле {FFD700}включено.")
        else
            loadMsg("Авто-АФК при активной ловле {FFD700}выключено.")
        end
    end)

    -- ===== AFK ПРИ АКТИВНОЙ ЛОВЛЕ =====
    local AFK_MAX_DURATION = 4 * 60 + 50 -- 4м50с — после этого АФК автоматически отключается, пока ловля не будет перезапущена
    local afkX, afkY, afkZ = 0, 0, 0
    lua_thread.create(function()
        while true do
            wait(0)
            local withinAfkWindow = (startTime == 0) or (os.time() - startTime) < AFK_MAX_DURATION
            local shouldAfk = afkEnabled and active and withinAfkWindow
            if shouldAfk and not afkActive then
                -- входим в АФК: запоминаем точку
                afkX, afkY, afkZ = getCharCoordinates(PLAYER_PED)
            elseif not shouldAfk and afkActive then
                -- выходим из АФК: возвращаемся на точку
                setCharCoordinates(PLAYER_PED, afkX, afkY, afkZ)
            end
            afkActive = shouldAfk
        end
    end)
    -- ==================================


    -- ===== KEY HANDLER =====
    lua_thread.create(function()
        while true do
            wait(0)
            if waitingForKey then
                local key = getPressedKey()
                if key then
                    cfg.key = key
                    waitingForKey = false
                    saveSettings()
                    loadMsg("Клавиша сохранена: {FFD700}" .. getKeyName(key))
                    if menu._reopenAfter then
                        menu._reopenAfter = false
                        openMenu()
                    end
                end
            else
                if isKeyDown(cfg.key) then
                    local inChat = sampIsChatInputActive()
                    local inCmd  = sampIsDialogActive()
                    if not inChat and not inCmd then
                        needToggle = true
                        while isKeyDown(cfg.key) do wait(0) end
                    end
                end
            end
        end
    end)
    -- =======================

    lua_thread.create(function()
        local prevCaught, prevWinOpen = false, false
        while true do
            wait(100)
            if active then
                local caught  = isReportCaught()
                local winOpen = isReportWindowOpen()
                if (caught and not prevCaught) or (winOpen and not prevWinOpen) then
                    active = false
                    if spamThread then spamThread.status = "dead"; spamThread = nil end
                    loadMsg("Репорт {FFD700}пойман! {FFFFFF}Ловля остановлена автоматически.")
                    notifyIfMinimized()
                    triggerCatchAnimation()
                end
                prevCaught  = caught
                prevWinOpen = winOpen
            else
                prevCaught  = false
                prevWinOpen = false
            end
        end
    end)

    print(("[DBG %.2f] main(): ВСЯ ИНИЦИАЛИЗАЦИЯ ЗАВЕРШЕНА, входим в главный цикл while true"):format(os.clock()))
    while true do
        wait(0)
        if needToggle then
            print(("[DBG %.2f] main(): needToggle сработал, protectionActive=%s"):format(os.clock(), tostring(protectionActive)))
            needToggle = false
            if protectionActive then
                -- блокируем переключение пока активна защита
                print(("[DBG %.2f] main(): переключение ЗАБЛОКИРОВАНО из-за protectionActive"):format(os.clock()))
            else
            active = not active
            print(("[DBG %.2f] main(): active теперь = %s"):format(os.clock(), tostring(active)))
            if active then
                startTime     = os.time()
                commandCount  = 0
                attemptsCount = 0
                missedCount   = 0
                att.display   = 0
                att.from      = 0
                att.to        = 0
                antifloodPause = false
                catchAnim.active = false
                initTimerFlip("00:00")
                initPingFlip(tostring(ping.val))
                showWindow[0] = true
                triggerSlideAnim()
                playSound(sounds.enable)
                lastSpamTime = getTickCount()
                lastNoQuestionsTime = os.clock()
                spamThread = lua_thread.create(spamFunction)
            else
                catchAnim.active = false
                notifyAnim.active = false
                notifyAnim.ending = false
                notifyAnim2.active = false
                notifyAnim2.ending = false
                if spamThread then spamThread.status = "dead"; spamThread = nil end
                triggerSlideOutAnim()
                playSound(sounds.disable)
            end
            end
        end
    end
end

function cmdSetPos()
    settingPosition = true
    showWindow[0] = true
    loadMsg("Переместите окно мышью и нажмите ЛКМ для сохранения позиции")
end

function cmdSetKey()
    if not checkAndWarn() then
        if menu._reopenAfter then
            menu._reopenAfter = false
            openMenu()
        end
        return
    end
    waitingForKey = true
    loadMsg("Нажмите клавишу, которую хотите назначить для активации...")
end

function loadSettings()
    if doesFileExist(SETTINGS_FILE) then
        local file = io.open(SETTINGS_FILE, "r")
        if file then
            for line in file:lines() do
                local key, value = line:match("^([^=]+)=(.+)$")
                if key and value then
                    key   = key:gsub("^%s*(.-)%s*$", "%1")
                    value = value:gsub("^%s*(.-)%s*$", "%1")
                    if     key == "WINDOW_X"     then window.x = tonumber(value) or window.x
                    elseif key == "WINDOW_Y"     then window.y = tonumber(value) or window.y
                    elseif key == "CFG_KEY"     then cfg.key = tonumber(value) or cfg.key
                    elseif key == "FIRST_LAUNCH"       then firstLaunch = (value == "true")
                    elseif key == "NOTIFY_MINIMIZED"  then notifyMinimizedEnabled = (value ~= "false")
                    elseif key == "AFK_ENABLED"       then afkEnabled = (value == "true")
                    end
                end
            end
            file:close()
        end
    end
end

function saveSettings()
    local file = io.open(SETTINGS_FILE, "w")
    if file then
        file:write("WINDOW_X=" .. window.x .. "\n")
        file:write("WINDOW_Y=" .. window.y .. "\n")
        file:write("CFG_KEY=" .. cfg.key .. "\n")
        file:write("FIRST_LAUNCH=false\n")
        file:write("NOTIFY_MINIMIZED=" .. (notifyMinimizedEnabled and "true" or "false") .. "\n")
        file:write("AFK_ENABLED=" .. (afkEnabled and "true" or "false") .. "\n")
        file:close()
    end
end

-- ===================== МИГРАЦИЯ СО СТАРЫХ ФАЙЛОВ =====================
-- Раньше настройки хранились в отдельном файле (spam_settings.ini). Если
-- единый файл ещё не создан, а старый файл есть — переносим данные в новый
-- единый файл и удаляем старый файл.
function migrateLegacySettings()
    if doesFileExist(SETTINGS_FILE) then return end -- новый файл уже существует, миграция не нужна

    local foundLegacy = false

    if doesFileExist(LEGACY_SETTINGS_FILE) then
        foundLegacy = true
        local file = io.open(LEGACY_SETTINGS_FILE, "r")
        if file then
            for line in file:lines() do
                local key, value = line:match("^([^=]+)=(.+)$")
                if key and value then
                    key   = key:gsub("^%s*(.-)%s*$", "%1")
                    value = value:gsub("^%s*(.-)%s*$", "%1")
                    if     key == "WINDOW_X"          then window.x = tonumber(value) or window.x
                    elseif key == "WINDOW_Y"          then window.y = tonumber(value) or window.y
                    elseif key == "CFG_KEY"           then cfg.key = tonumber(value) or cfg.key
                    elseif key == "FIRST_LAUNCH"      then firstLaunch = (value == "true")
                    elseif key == "NOTIFY_MINIMIZED"  then notifyMinimizedEnabled = (value ~= "false")
                    elseif key == "AFK_ENABLED"       then afkEnabled = (value == "true")
                    end
                end
            end
            file:close()
        end
    end

    if foundLegacy then
        saveSettings() -- сохраняем всё в единый новый файл

        if doesFileExist(LEGACY_SETTINGS_FILE) then os.remove(LEGACY_SETTINGS_FILE) end
    end
end

function getPressedKey()
    for key = 1, 256 do
        if isKeyDown(key) then
            while isKeyDown(key) do wait(0) end
            return key
        end
    end
    return nil
end

function sampev.onServerMessage(color, text)
    if text:find('Сейчас нет вопросов в репорт') then
        lastNoQuestionsTime = os.clock()
        return false
    end

    if active then
        if text:find('Не флуди') or text:find('флуд') or (text:find('%[Ошибка%]') and text:find('флуд')) then
            if not antifloodPause then
                antifloodPause = true
                local afSlot = (notifyAnim.active or notifyAnim.ending) and notifyAnim2 or notifyAnim
                showNotify(u8"пауза: анти-флуд", 1.0, 0.8, 0.0, 0, false)
                lua_thread.create(function()
                    wait(1500)
                    antifloodPause = false
                    hideNotify(afSlot)
                    lastSpamTime = getTickCount()
                end)
            end
            return false
        end
        if text:find('%[(%W+)%] от (%w+_%w+)%[(%d+)%]:') then
            if not antifloodPause then
                attemptsCount = attemptsCount + 1
                triggerAttemptsAnim(attemptsCount)
                local snapCount = attemptsCount
                lua_thread.create(function()
                    wait(100)
                    if active and attemptsCount == snapCount and not catchAnim.active then
                        st.missedDelta = st.missedDelta + 1
                        missedCount    = missedCount + 1
                        showNotify(u8"пропустили репорт", 1.0, 0.32, 0.32, 2800, false)
                    end
                end)
                sampSendChat(cfg.cmd)
                commandCount = commandCount + 1
            end
        end
    end
end

function spamFunction()
    while active do
        if not antifloodPause then
            local currentTime = getTickCount()
            if currentTime - lastSpamTime >= cfg.interval then
                lastSpamTime = currentTime
                for i = 1, cfg.count do
                    if not active then break end
                    sampSendChat(cfg.cmd)
                    commandCount = commandCount + 1
                    if i < cfg.count then wait(cfg.delay) end
                end
                local startWait = getTickCount()
                while active and (getTickCount() - startWait) < cfg.interval do wait(50) end
            end
        end
        wait(0)
    end
end

function wasKeyPressed(key)
    if isKeyDown(key) then
        while isKeyDown(key) do wait(0) end
        return true
    end
    return false
end

function getTickCount()
    return os.clock() * 1000
end
-- Завершение скрипта
function onScriptTerminate(scr, quitGame)
    -- stub
end