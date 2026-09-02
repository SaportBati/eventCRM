-- 2
local vkeys    = require("vkeys")
local lfs      = require("lfs")
local effil    = require("effil")
local encoding = require("encoding")
local dkjson   = require("dkjson")
local imgui    = require("mimgui")
local ffi      = require("ffi")

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local function to_utf8(str)
    if not str or str == "" then return str end
    local ok, res = pcall(function() return u8:encode(str) end)
    if ok and res then return res end
    return str
end

local SCRIPT_DIR = thisScript().path:match("^(.*[\\/])") or ""

-- ==================== Кастомный шрифт для всех окон ====================
-- Шрифт качается один раз с GitHub и кешируется рядом со скриптом; если по
-- какой-то причине скачать/загрузить его не удалось, всё молча откатывается
-- на дефолтный/системные шрифты — окна не ломаются.
local CUSTOM_FONT_URL   = "https://raw.githubusercontent.com/SaportBati/eventCRM/refs/heads/main/eventscrin.ttf"
local CUSTOM_FONT_FILE  = SCRIPT_DIR .. "eventscrin.ttf"
local CUSTOM_FONT_SIZE  = 16.0
local custom_font       = nil

local function is_custom_font_cached()
    local f = io.open(CUSTOM_FONT_FILE, "rb")
    if not f then return false end
    f:close()
    return true
end

-- Однократная (блокирующая) загрузка при первом запуске — файла ещё нет,
-- а грузить настоящий шрифт окна должны уже к моменту imgui.OnInitialize.
-- В дальнейших запусках файл уже лежит на диске и сеть не трогаем вообще.
local function ensure_custom_font_downloaded()
    if is_custom_font_cached() then return true end

    local ok_req, requests = pcall(require, "requests")
    if not ok_req or not requests then return false end

    local ok_get, resp = pcall(requests.get, CUSTOM_FONT_URL, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" }
    })
    if not ok_get or not resp or resp.status_code ~= 200 or not resp.text or #resp.text == 0 then
        return false
    end

    local file = io.open(CUSTOM_FONT_FILE, "wb")
    if not file then return false end
    file:write(resp.text)
    file:close()
    return true
end

ensure_custom_font_downloaded()

-- ==================== Отдельный крупный шрифт для тоста ====================
-- SetWindowFontScale просто растягивает уже отрисованный битмап шрифта (мыло),
-- поэтому для чёткого крупного текста строим настоящий шрифт нужного размера.
local TOAST_FONT_SIZE = 27.0
local toast_font = nil

local FONT_CANDIDATES = {
    (os.getenv("WINDIR") or "C:\\Windows") .. "\\Fonts\\segoeui.ttf",
    (os.getenv("WINDIR") or "C:\\Windows") .. "\\Fonts\\tahoma.ttf",
    (os.getenv("WINDIR") or "C:\\Windows") .. "\\Fonts\\arial.ttf",
}

imgui.OnInitialize(function()
    local ok_io, imgui_io = pcall(imgui.GetIO)
    if not ok_io or not imgui_io then return end

    local ranges = nil
    local ok_ranges, cyr = pcall(function() return imgui_io.Fonts:GetGlyphRangesCyrillic() end)
    if ok_ranges then ranges = cyr end

    -- Кастомный шрифт (eventscrin.ttf) как шрифт по умолчанию для всех окон
    if is_custom_font_cached() then
        local ok_cf, font = pcall(function()
            return imgui_io.Fonts:AddFontFromFileTTF(CUSTOM_FONT_FILE, CUSTOM_FONT_SIZE, nil, ranges)
        end)
        if ok_cf and font then
            custom_font        = font
            imgui_io.FontDefault = font
        end
    end

    -- Крупный шрифт для тоста: тот же кастомный шрифт, увеличенный,
    -- либо системный как запасной вариант, если кастомный не загрузился
    if is_custom_font_cached() then
        local ok_tf, font = pcall(function()
            return imgui_io.Fonts:AddFontFromFileTTF(CUSTOM_FONT_FILE, TOAST_FONT_SIZE, nil, ranges)
        end)
        if ok_tf and font then
            toast_font = font
        end
    end

    if not toast_font then
        for _, path in ipairs(FONT_CANDIDATES) do
            local f = io.open(path, "rb")
            if f then
                f:close()
                local ok_font, font = pcall(function()
                    return imgui_io.Fonts:AddFontFromFileTTF(path, TOAST_FONT_SIZE, nil, ranges)
                end)
                if ok_font and font then
                    toast_font = font
                    break
                end
            end
        end
    end
end)

local TAG = "{05ff12}[{05f911}E{04f310}v{04ed0f}e{03e70e}n{03e10d}t{02db0c}S{02d50b}c{01cf0a}a{01c909}n{00a609}]"

local function es_msg(text, body_color)
    body_color = body_color or "FFFFFF"
    sampAddChatMessage(TAG .. " {" .. body_color .. "}" .. text, 0x05ff12)
end

local WORKER_URL_PRIMARY  = "https://bitter-breeze-2c7b.vitadensikloh.workers.dev/"
local WORKER_URL_FALLBACK = "https://nehto--9aade89ea49811f1a9051607ee4eb77e.web.val.run"

local active_worker_url = WORKER_URL_PRIMARY
local WORKER_TOKEN = "SET_YOUR_OWN_SECRET_HERE"
local SCAN_RADIUS  = 200.0

local SCRIPT_VERSION      = "1.3"
local VERSION_CHECK_URL   = "https://raw.githubusercontent.com/SaportBati/eventCRM/refs/heads/main/version.txt"
local UPDATE_DOWNLOAD_URL = "https://raw.githubusercontent.com/SaportBati/eventCRM/refs/heads/main/event.lua"

local update_available     = false
local update_remote_version = nil
local update_in_progress   = false

local pending_reports = {}
local pending_scans = {}
local DETECTION_POLL_INTERVAL = 100

local unique_players       = {}
local unique_players_order = {}
local scanning_active      = false

local active_threads = {}

local LOCAL_DB_FILE  = SCRIPT_DIR .. "event_scan_reports.json"
local SCREENS_CACHE_FILE = SCRIPT_DIR .. "screens_path_cache.txt"
local HWID_CACHE_FILE = SCRIPT_DIR .. "hwid_cache.txt"

local function load_local_reports()
    local file = io.open(LOCAL_DB_FILE, "r")
    if not file then return {} end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(dkjson.decode, content)
    if ok and type(data) == "table" then return data end
    return {}
end

local function save_local_reports(data)
    local file = io.open(LOCAL_DB_FILE, "w")
    if not file then return false end
    file:write(dkjson.encode(data, { indent = true }))
    file:close()
    return true
end

local local_reports = load_local_reports()

local function add_local_report(date_str, send_time_str, scans, event_name, winner_nick, players, author_nick)
    table.insert(local_reports, {
        date    = date_str,
        time    = send_time_str,
        scans   = scans,
        event   = event_name,
        winner  = winner_nick,
        players = players or {},
        author  = author_nick or ""
    })
    save_local_reports(local_reports)
end

local function distance3d(x1, y1, z1, x2, y2, z2)
    return math.sqrt(((x2-x1)^2) + ((y2-y1)^2) + ((z2-z1)^2))
end

local function get_local_nickname()
    local result, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if result then
        local name = sampGetPlayerNickname(id)
        if name and name ~= "" then return name end
    end
    return "Unknown"
end

local function scan_nearby_players_once()
    local myX, myY, myZ = getCharCoordinates(PLAYER_PED)
    for id = 0, 1000 do
        if sampIsPlayerConnected(id) then
            local result, ped = sampGetCharHandleBySampPlayerId(id)
            if result and doesCharExist(ped) and ped ~= PLAYER_PED then
                local x, y, z = getCharCoordinates(ped)
                local dist = distance3d(x, y, z, myX, myY, myZ)
                if dist <= SCAN_RADIUS then
                    local name = sampGetPlayerNickname(id)
                    if name and not unique_players[name] then
                        unique_players[name] = true
                        table.insert(unique_players_order, name)
                    end
                end
            end
        end
    end
end

local function start_detection_loop()
    if scanning_active then return end
    scanning_active = true
    lua_thread.create(function()
        while scanning_active do
            scan_nearby_players_once()
            wait(DETECTION_POLL_INTERVAL)
        end
    end)
end

local function stop_detection_loop()
    scanning_active = false
end

local function get_readable_time()
    local t = os.time() + 10800
    return os.date("!%d.%m.%Y %H:%M:%S", t)
end

-- ==================== Хелперы дат/времени для планировщика (/esp) ====================

local DOW_LABELS_RU = { "Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб" }

-- ВАЖНО: планировщик (/esp) всегда работает по МСК (UTC+3), как и сервер
-- (воркер /plan, /check-hwid) и сайт plan.html — независимо от того, какой
-- часовой пояс выставлен на компьютере игрока. Поэтому даты/эпохи здесь
-- считаются вручную через os.time()+MSK_OFFSET и os.date("!..."), а не через
-- os.date("*t")/os.time(table), которые интерпретируют значения в ЛОКАЛЬНОЙ
-- таймзоне ПК и на не-MSK машинах сдвигали бы список дат и блокировку
-- прошедших слотов на разницу поясов.
local MSK_OFFSET = 10800

local function format_date_ymd(t)
    return os.date("!%Y-%m-%d", t)
end

-- 5 дней назад + сегодня + 3 дня вперёд = 9 дней, как в plan.html
local function espl_get_date_range()
    local days = {}
    local msk_now      = os.time() + MSK_OFFSET
    local msk_midnight = msk_now - (msk_now % 86400)
    for offset = -5, 3 do
        table.insert(days, msk_midnight + offset * 86400)
    end
    return days
end

-- Слоты по 20 минут, 24 часа = 72 слота на день, как в plan.html
local function espl_generate_time_slots()
    local slots = {}
    for hour = 0, 23 do
        for minute = 0, 59, 20 do
            table.insert(slots, string.format("%02d:%02d", hour, minute))
        end
    end
    return slots
end

-- Дни от гражданской эпохи (алгоритм Hinnant, UTC-safe), чтобы не зависеть
-- от os.time(table), который трактует поля как ЛОКАЛЬНОЕ время ПК.
local function espl_days_from_civil(y, m, d)
    y = y - ((m <= 2) and 1 or 0)
    local era = math.floor((y >= 0 and y or y - 399) / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + ((m > 2) and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- Возвращает настоящий UTC-epoch, соответствующий указанному дню/времени
-- по МСК — не зависит от часового пояса, выставленного на компьютере игрока.
local function espl_slot_epoch(date_str, time_str)
    local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
    local h, mi = time_str:match("(%d+):(%d+)")
    local days = espl_days_from_civil(tonumber(y), tonumber(m), tonumber(d))
    local naive_msk_epoch = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60
    return naive_msk_epoch - MSK_OFFSET
end

local function espl_is_past(date_str, time_str)
    return espl_slot_epoch(date_str, time_str) < os.time()
end

local function is_dir(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "directory"
end

local function load_cached_hwid()
    local file = io.open(HWID_CACHE_FILE, "r")
    if not file then return nil end
    local hwid = file:read("*l")
    file:close()
    if hwid and hwid ~= "" then return hwid end
    return nil
end

local function save_cached_hwid(hwid)
    local file = io.open(HWID_CACHE_FILE, "w")
    if not file then return false end
    file:write(hwid)
    file:close()
    return true
end

local cached_hwid = nil

local function get_hwid()
    return cached_hwid
end

local function copy_to_clipboard(text)
    if not text or text == "" then return false end

    local ok = pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[
            typedef int BOOL;
            typedef void* HANDLE;
            typedef void* HWND;
            typedef unsigned int UINT;
            BOOL OpenClipboard(HWND hWndNewOwner);
            BOOL CloseClipboard(void);
            BOOL EmptyClipboard(void);
            HANDLE SetClipboardData(UINT uFormat, HANDLE hMem);
            HANDLE GlobalAlloc(UINT uFlags, size_t dwBytes);
            void* GlobalLock(HANDLE hMem);
            BOOL GlobalUnlock(HANDLE hMem);
        ]]

        local user32   = ffi.load("user32")
        local kernel32 = ffi.load("kernel32")

        local GMEM_MOVEABLE = 0x0002
        local CF_TEXT        = 1

        if user32.OpenClipboard(nil) == 0 then error("open_fail") end

        local success = pcall(function()
            user32.EmptyClipboard()

            local size = #text + 1
            local hMem = kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
            if hMem == nil then error("alloc_fail") end

            local ptr = kernel32.GlobalLock(hMem)
            if ptr == nil then error("lock_fail") end

            ffi.copy(ptr, text, size)
            kernel32.GlobalUnlock(hMem)

            user32.SetClipboardData(CF_TEXT, hMem)
        end)

        user32.CloseClipboard()
        if not success then error("write_fail") end
    end)

    return ok
end

local function is_hwid_error(err)
    return err ~= nil and tostring(err):find("hwid_not_allowed") ~= nil
end

local function notify_hwid_denied()
    copy_to_clipboard(get_hwid() or "UNKNOWN")
    es_msg("Твой HWID не добавлен в систему!", "FF4444")
    es_msg("Он скопирован в буфер обмена — отправь его разработчику, чтобы тебя добавили.", "FF4444")
end

local function screenshot_upload_worker(channel, worker_url, token, binary_data, hwid)
    local requests = require("requests")
    local json     = require("dkjson")

    local function encodeBase64(data)
        local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        local result, pad = {}, 0
        for i = 1, #data, 3 do
            local b1, b2, b3 = data:byte(i) or 0, data:byte(i+1) or 0, data:byte(i+2) or 0
            if i+1 > #data then pad = 2 elseif i+2 > #data then pad = 1 end
            local n = b1*65536 + b2*256 + b3
            result[#result+1] = b64chars:sub(math.floor(n/262144)%64+1, math.floor(n/262144)%64+1)
            result[#result+1] = b64chars:sub(math.floor(n/4096)%64+1, math.floor(n/4096)%64+1)
            result[#result+1] = (pad < 2) and b64chars:sub(math.floor(n/64)%64+1, math.floor(n/64)%64+1) or '='
            result[#result+1] = (pad < 1) and b64chars:sub(n%64+1, n%64+1) or '='
        end
        return table.concat(result)
    end

    local payload = json.encode({ data = encodeBase64(binary_data) })

    local ok, response = pcall(requests.request, "POST", worker_url .. "/upload-image", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Auth-Token"] = token,
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload
    })

    if not ok or not response then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if response.status_code == 200 then
        local pok, res_data = pcall(json.decode, response.text)
        if pok and res_data and res_data.ok and res_data.url then
            channel:push({ ok = true, url = res_data.url })
        else
            channel:push({ ok = false, err = "json_parse_fail" })
        end
    else
        local err_detail = "http_" .. tostring(response.status_code)
        local pok, res_data = pcall(json.decode, response.text or "")
        if pok and res_data and res_data.error then
            err_detail = err_detail .. " (" .. tostring(res_data.error) .. ")"
        end
        channel:push({ ok = false, err = err_detail })
    end
end

local function d1_report_worker(channel, worker_url, token, payload_json, hwid)
    local requests = require("requests")
    local json     = require("dkjson")

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/report", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Auth-Token"] = token,
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload_json
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 or resp.status_code == 201 then
        channel:push({ ok = true })
        return
    end

    local err_detail = "http_" .. tostring(resp.status_code)
    local pok, res_data = pcall(json.decode, resp.text or "")
    if pok and res_data then
        if res_data.error then
            err_detail = err_detail .. " (" .. tostring(res_data.error) .. ")"
        end
        if res_data.detail then
            err_detail = err_detail .. ": " .. tostring(res_data.detail)
        end
    end
    channel:push({ ok = false, err = err_detail })
end

local function gen_token_worker(channel, worker_url, token, hwid)
    local requests = require("requests")
    local json     = require("dkjson")

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/gen-token", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Auth-Token"] = token,
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = "{}"
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 then
        local pok, res_data = pcall(json.decode, resp.text)
        if pok and res_data and res_data.ok and res_data.token then
            channel:push({ ok = true, token = res_data.token })
        else
            channel:push({ ok = false, err = "json_parse_fail" })
        end
    else
        local err_detail = "http_" .. tostring(resp.status_code)
        local pok, res_data = pcall(json.decode, resp.text or "")
        if pok and res_data and res_data.error then
            err_detail = err_detail .. " (" .. tostring(res_data.error) .. ")"
        end
        channel:push({ ok = false, err = err_detail })
    end
end

local function d1_last_report_worker(channel, worker_url, token)
    local requests = require("requests")
    local json     = require("dkjson")

    local ok, resp = pcall(requests.get, worker_url .. "/last", {
        headers = {
            ["X-Auth-Token"] = token,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        }
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 then
        local pok, data = pcall(json.decode, resp.text)
        if pok and data and data.ok and data.date then
            channel:push({ ok = true, date = data.date })
        else
            channel:push({ ok = false, err = "no_reports" })
        end
    else
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
    end
end

-- ==================== Воркеры планировщика (/esp, аналог plan.html) ====================

local function plan_fetch_worker(channel, worker_url, date)
    local requests = require("requests")
    local json     = require("dkjson")

    local ok, resp = pcall(requests.get, worker_url .. "/plan?date=" .. date, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" }
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 then
        local pok, data = pcall(json.decode, resp.text)
        if pok and data and data.ok then
            channel:push({ ok = true, slots = data.slots or {} })
        else
            channel:push({ ok = false, err = "json_parse_fail" })
        end
    else
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
    end
end

local function plan_save_worker(channel, worker_url, hwid, date, time, title)
    local requests = require("requests")
    local json     = require("dkjson")

    local payload = json.encode({ date = date, time = time, title = title })

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/plan", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    local pok, data = pcall(json.decode, resp.text or "")
    if resp.status_code == 200 and pok and data and data.ok then
        channel:push({ ok = true, author = data.author, title = data.title })
    else
        local err_detail = (pok and data and data.error) or ("http_" .. tostring(resp.status_code))
        channel:push({ ok = false, err = err_detail })
    end
end

local function plan_delete_worker(channel, worker_url, hwid, date, time)
    local requests = require("requests")
    local json     = require("dkjson")

    local payload = json.encode({ date = date, time = time })

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/plan/delete", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    local pok, data = pcall(json.decode, resp.text or "")
    if resp.status_code == 200 and pok and data and data.ok then
        channel:push({ ok = true })
    else
        local err_detail = (pok and data and data.error) or ("http_" .. tostring(resp.status_code))
        channel:push({ ok = false, err = err_detail })
    end
end

local function check_hwid_worker(channel, worker_url, hwid)
    local requests = require("requests")
    local json     = require("dkjson")

    local ok, resp = pcall(requests.get, worker_url .. "/check-hwid", {
        headers = {
            ["X-HWID"]     = hwid,
            ["User-Agent"] = "SAMP-EventScan/1.4"
        }
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 then
        local pok, data = pcall(json.decode, resp.text)
        if pok and data and data.ok then
            channel:push({ ok = true, allowed = data.allowed, author = data.author })
        else
            channel:push({ ok = false, err = "json_parse_fail" })
        end
    else
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
    end
end

local function version_check_worker(channel, url)
    local requests = require("requests")

    local ok, resp = pcall(requests.get, url, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" }
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 and resp.text then
        local version = resp.text:match("%S+")
        if version then
            channel:push({ ok = true, version = version })
        else
            channel:push({ ok = false, err = "empty_version" })
        end
    else
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
    end
end

local function update_download_worker(channel, url)
    local requests = require("requests")

    local ok, resp = pcall(requests.get, url, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" }
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 and resp.text and #resp.text > 0 then
        channel:push({ ok = true, data = resp.text })
    else
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
    end
end

local function open_url_worker(channel, url)
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi then
        channel:push({ ok = false, err = "no_ffi" })
        return
    end

    local ok_cdef = pcall(function()
        ffi.cdef[[
            void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile,
                                 const char* lpParameters, const char* lpDirectory, int nShowCmd);
        ]]
    end)
    if not ok_cdef then
        channel:push({ ok = false, err = "cdef_fail" })
        return
    end

    local ok_load, shell32 = pcall(ffi.load, "shell32")
    if not ok_load or not shell32 then
        channel:push({ ok = false, err = "shell32_load_fail" })
        return
    end

    local SW_SHOWNORMAL = 1
    local ok_call, result = pcall(shell32.ShellExecuteA, nil, "open", url, nil, nil, SW_SHOWNORMAL)
    if not ok_call then
        channel:push({ ok = false, err = "shellexecute_fail" })
        return
    end

    local code = tonumber(ffi.cast("intptr_t", result)) or 0
    channel:push({ ok = code > 32, code = code })
end

local function browse_folder_worker(channel, title_utf8)
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi then
        channel:push({ ok = false, err = "no_ffi" })
        return
    end

    local ok_cdef = pcall(function()
        ffi.cdef[[
            typedef struct {
                void*        hwndOwner;
                void*        pidlRoot;
                wchar_t*     pszDisplayName;
                const wchar_t* lpszTitle;
                unsigned int ulFlags;
                void*        lpfn;
                intptr_t     lParam;
                int          iImage;
            } BROWSEINFOW;

            int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
                                     const char* lpMultiByteStr, int cbMultiByte,
                                     wchar_t* lpWideCharStr, int cchWideChar);
            int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags,
                                     const wchar_t* lpWideCharStr, int cchWideChar,
                                     char* lpMultiByteStr, int cbMultiByte,
                                     const char* lpDefaultChar, int* lpUsedDefaultChar);

            long CoInitializeEx(void* pvReserved, unsigned long dwCoInit);
            void CoUninitialize(void);
            void CoTaskMemFree(void* pv);

            void* SHBrowseForFolderW(BROWSEINFOW* lpbi);
            int   SHGetPathFromIDListW(void* pidl, wchar_t* pszPath);
        ]]
    end)
    if not ok_cdef then
        channel:push({ ok = false, err = "cdef_fail" })
        return
    end

    local ok_load1, kernel32 = pcall(ffi.load, "kernel32")
    local ok_load2, ole32    = pcall(ffi.load, "ole32")
    local ok_load3, shell32  = pcall(ffi.load, "shell32")
    if not (ok_load1 and ok_load2 and ok_load3) then
        channel:push({ ok = false, err = "dll_load_fail" })
        return
    end

    local CP_UTF8 = 65001
    local CP_ACP  = 0
    local COINIT_APARTMENTTHREADED = 0x2

    ole32.CoInitializeEx(nil, COINIT_APARTMENTTHREADED)

    local title_wide = ffi.new("wchar_t[260]")
    kernel32.MultiByteToWideChar(CP_UTF8, 0, title_utf8, -1, title_wide, 260)

    local display_name = ffi.new("wchar_t[260]")

    local BIF_RETURNONLYFSDIRS = 0x0001
    local BIF_NEWDIALOGSTYLE   = 0x0040

    local bi = ffi.new("BROWSEINFOW")
    bi.hwndOwner      = nil
    bi.pidlRoot       = nil
    bi.pszDisplayName = display_name
    bi.lpszTitle      = title_wide
    bi.ulFlags        = BIF_RETURNONLYFSDIRS + BIF_NEWDIALOGSTYLE
    bi.lpfn           = nil
    bi.lParam         = 0
    bi.iImage         = 0

    local ok_call, pidl = pcall(shell32.SHBrowseForFolderW, bi)
    if not ok_call or pidl == nil then
        ole32.CoUninitialize()
        channel:push({ ok = false, err = "cancelled" })
        return
    end

    local path_wide = ffi.new("wchar_t[260]")
    local got_path = shell32.SHGetPathFromIDListW(pidl, path_wide)
    ole32.CoTaskMemFree(pidl)

    if got_path == 0 then
        ole32.CoUninitialize()
        channel:push({ ok = false, err = "path_fail" })
        return
    end

    local needed = kernel32.WideCharToMultiByte(CP_ACP, 0, path_wide, -1, nil, 0, nil, nil)
    local path_ansi = nil
    if needed > 0 then
        local buf = ffi.new("char[?]", needed)
        kernel32.WideCharToMultiByte(CP_ACP, 0, path_wide, -1, buf, needed, nil, nil)
        path_ansi = ffi.string(buf, needed - 1)
    end

    ole32.CoUninitialize()

    if path_ansi and path_ansi ~= "" then
        channel:push({ ok = true, path = path_ansi })
    else
        channel:push({ ok = false, err = "empty_path" })
    end
end

local function wait_for_channel(channel, timeout_ms)
    local waited = 0
    local POLL = 30
    while waited < timeout_ms do
        local data = channel:pop(0)
        if data ~= nil then
            return data
        end
        wait(POLL)
        waited = waited + POLL
    end
    return nil
end

local PRIMARY_WORKER_TIMEOUT_MS = 2000

local function try_worker_urls(worker_fn, build_args, timeout_ms)
    local function attempt(url, attempt_timeout_ms)
        local channel = effil.channel()
        local args = build_args(url)
        local thr = effil.thread(worker_fn)(channel, url, unpack(args))
        active_threads[#active_threads+1] = thr
        return wait_for_channel(channel, attempt_timeout_ms)
    end

    local has_fallback    = active_worker_url ~= WORKER_URL_FALLBACK
    local primary_timeout = has_fallback and math.min(PRIMARY_WORKER_TIMEOUT_MS, timeout_ms) or timeout_ms

    local result = attempt(active_worker_url, primary_timeout)
    if result and result.ok then
        return result
    end

    if has_fallback then
        print(string.format("[EventScan] Основной Worker (%s) не ответил: %s. Пробую резервный (%s)...",
            active_worker_url, tostring(result and result.err or "unknown_error"), WORKER_URL_FALLBACK))

        local fallback_result = attempt(WORKER_URL_FALLBACK, timeout_ms)
        if fallback_result and fallback_result.ok then
            active_worker_url = WORKER_URL_FALLBACK
            print(string.format("[EventScan] Резервный Worker (%s) сработал. Переключаюсь на него до конца сессии.", WORKER_URL_FALLBACK))
            return fallback_result
        end

        print(string.format("[EventScan] Резервный Worker (%s) тоже не ответил: %s.",
            WORKER_URL_FALLBACK, tostring(fallback_result and fallback_result.err or "unknown_error")))

        return fallback_result or result
    end

    return result
end

local function generate_hwid_worker(channel)
    local UUID_PATTERN = "(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)"

    local INVALID_UUIDS = {
        ["FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"] = true,
        ["00000000-0000-0000-0000-000000000000"] = true,
    }

    local function run_and_extract_uuid(command)
        local ok, handle = pcall(io.popen, command)
        if not ok or not handle then return nil end
        local result = handle:read("*a")
        handle:close()
        if not result then return nil end

        local uuid = result:match(UUID_PATTERN)
        if not uuid then return nil end

        uuid = uuid:upper()
        if INVALID_UUIDS[uuid] then return nil end
        return uuid
    end

    local uuid = run_and_extract_uuid("wmic csproduct get uuid 2>NUL")

    if not uuid then
        uuid = run_and_extract_uuid(
            'powershell -NoProfile -Command "(Get-CimInstance -ClassName Win32_ComputerSystemProduct).UUID" 2>NUL'
        )
    end

    if not uuid then
        uuid = run_and_extract_uuid(
            'reg query "HKLM\\SOFTWARE\\Microsoft\\Cryptography" /v MachineGuid 2>NUL'
        )
    end

    if uuid then
        channel:push({ ok = true, hwid = uuid })
        return
    end

    channel:push({
        ok = false,
        hwid = "FALLBACK-" .. tostring(os.getenv("COMPUTERNAME") or "PC") .. "-" .. tostring(os.getenv("USERNAME") or "USER")
    })
end

local function resolve_hwid(callback)
    local cached = load_cached_hwid()
    if cached then
        cached_hwid = cached
        if callback then callback(cached_hwid) end
        return
    end

    local channel = effil.channel()
    local thr = effil.thread(generate_hwid_worker)(channel)
    active_threads[#active_threads+1] = thr

    lua_thread.create(function()
        local result = wait_for_channel(channel, 20000)

        local hwid
        if result and result.hwid and result.hwid ~= "" then
            hwid = result.hwid
        else
            hwid = "UNKNOWN-" .. tostring(os.time())
        end

        cached_hwid = hwid
        save_cached_hwid(hwid)

        if callback then callback(hwid) end
    end)
end

local function load_cached_screens_root()
    local file = io.open(SCREENS_CACHE_FILE, "r")
    if not file then return nil end
    local path = file:read("*l")
    file:close()
    if path and path ~= "" and is_dir(path) then
        return path
    end
    return nil
end

local function save_cached_screens_root(path)
    local file = io.open(SCREENS_CACHE_FILE, "w")
    if not file then return false end
    file:write(path)
    file:close()
    return true
end

local ok_cdef_folders = pcall(function()
    ffi.cdef[[
        long SHGetFolderPathW(void* hwndOwner, int nFolder, void* hToken, unsigned long dwFlags, wchar_t* pszPath);
        unsigned long GetLogicalDrives(void);
        unsigned int GetDriveTypeW(const wchar_t* lpRootPathName);
        int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
                                 const char* lpMultiByteStr, int cbMultiByte,
                                 wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags,
                                 const wchar_t* lpWideCharStr, int cchWideChar,
                                 char* lpMultiByteStr, int cbMultiByte,
                                 const char* lpDefaultChar, int* lpUsedDefaultChar);
    ]]
end)

local CSIDL_DESKTOP      = 0x0000
local CSIDL_PERSONAL     = 0x0005
local SHGFP_TYPE_CURRENT = 0
local DRIVE_REMOVABLE    = 2
local DRIVE_FIXED        = 3

local function ansi_to_wide(str)
    local ok_load, kernel32 = pcall(ffi.load, "kernel32")
    if not ok_load or not kernel32 then return nil end
    local wlen = kernel32.MultiByteToWideChar(0, 0, str, -1, nil, 0)
    if wlen <= 0 then return nil end
    local wbuf = ffi.new("wchar_t[?]", wlen)
    kernel32.MultiByteToWideChar(0, 0, str, -1, wbuf, wlen)
    return wbuf
end

local function wide_to_ansi(wide_buf)
    local ok_load, kernel32 = pcall(ffi.load, "kernel32")
    if not ok_load or not kernel32 then return nil end
    local needed = kernel32.WideCharToMultiByte(0, 0, wide_buf, -1, nil, 0, nil, nil)
    if needed <= 0 then return nil end
    local buf = ffi.new("char[?]", needed)
    kernel32.WideCharToMultiByte(0, 0, wide_buf, -1, buf, needed, nil, nil)
    return ffi.string(buf, needed - 1)
end

local function get_special_folder_path(csidl)
    local ok_load, shell32 = pcall(ffi.load, "shell32")
    if not ok_load or not shell32 then return nil end
    local path_wide = ffi.new("wchar_t[260]")
    local ok_call, hres = pcall(shell32.SHGetFolderPathW, nil, csidl, nil, SHGFP_TYPE_CURRENT, path_wide)
    if not ok_call or hres ~= 0 then return nil end
    local result = wide_to_ansi(path_wide)
    if not result or result == "" then return nil end
    return result
end

local function get_safe_drive_roots()
    local roots = {}
    local ok_bit, bit = pcall(require, "bit")
    local ok_load, kernel32 = pcall(ffi.load, "kernel32")
    if not ok_bit or not ok_load or not kernel32 then return roots end

    local ok_mask, mask = pcall(kernel32.GetLogicalDrives)
    if not ok_mask or not mask then return roots end

    for i = 0, 25 do
        if bit.band(mask, bit.lshift(1, i)) ~= 0 then
            local letter = string.char(65 + i)
            local root_path = letter .. ":\\"
            local wide_root = ansi_to_wide(root_path)
            if wide_root then
                local ok_type, dtype = pcall(kernel32.GetDriveTypeW, wide_root)
                if ok_type and (dtype == DRIVE_FIXED or dtype == DRIVE_REMOVABLE) then
                    table.insert(roots, letter .. ":")
                end
            end
        end
    end
    return roots
end

local SEARCH_MAX_DEPTH = 8
local SEARCH_MAX_DIRS  = 30000

local function search_arizona_screens(root)
    local visited = 0

    local function scan(path, depth, parent_name)
        if visited > SEARCH_MAX_DIRS or depth > SEARCH_MAX_DEPTH then
            return nil
        end

        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok or not iter then return nil end

        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                visited = visited + 1
                if visited % 50 == 0 then wait(0) end
                if visited > SEARCH_MAX_DIRS then return nil end

                local full = path .. "\\" .. entry
                local attr_ok, attr = pcall(lfs.attributes, full)
                if attr_ok and attr and attr.mode == "directory" then
                    local lname = entry:lower()
                    if lname == "screens" and parent_name == "arizona" then
                        return full
                    end
                    local found = scan(full, depth + 1, lname)
                    if found then return found end
                end
            end
        end
        return nil
    end

    return scan(root, 0, "")
end

local function search_file_by_name(root, target_name_lower)
    local visited = 0

    local function scan(path, depth)
        if visited > SEARCH_MAX_DIRS or depth > SEARCH_MAX_DEPTH then
            return nil
        end

        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok or not iter then return nil end

        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                visited = visited + 1
                if visited % 50 == 0 then wait(0) end
                if visited > SEARCH_MAX_DIRS then return nil end

                local full = path .. "\\" .. entry
                local attr_ok, attr = pcall(lfs.attributes, full)
                if attr_ok and attr then
                    if attr.mode == "file" and entry:lower() == target_name_lower then
                        return full
                    elseif attr.mode == "directory" then
                        local found = scan(full, depth + 1)
                        if found then return found end
                    end
                end
            end
        end
        return nil
    end

    return scan(root, 0)
end

local KNOWN_SCREENS_SUBPATHS = {
    "\\GTA San Andreas User Files\\SAMP\\arizona\\screens",
    "\\Games\\GTA San Andreas User Files\\SAMP\\arizona\\screens",
    "\\SAMP\\arizona\\screens",
    "\\arizona\\screens",
    "\\GTA San Andreas User Files\\Gallery"
}

local CHATLOG_KNOWN_SUBPATHS = {
    "\\GTA San Andreas User Files\\SAMP\\chatlog.txt",
    "\\Games\\GTA San Andreas User Files\\SAMP\\chatlog.txt",
    "\\SAMP\\chatlog.txt"
}

local function collect_primary_roots()
    local user_profile   = os.getenv("USERPROFILE")
    local documents_path = get_special_folder_path(CSIDL_PERSONAL)
    local desktop_path   = get_special_folder_path(CSIDL_DESKTOP)

    local roots = {}
    local seen = {}
    for _, p in ipairs({ documents_path, user_profile, desktop_path }) do
        if p and p ~= "" and not seen[p] then
            seen[p] = true
            table.insert(roots, p)
        end
    end
    return roots
end

local function try_known_subpaths(base_paths, subpaths)
    for _, base in ipairs(base_paths) do
        for _, sub in ipairs(subpaths) do
            local candidate = base .. sub
            if is_dir(candidate) then
                return candidate
            end
        end
    end
    return nil
end

local function find_screens_folder_everywhere()
    local primary_roots = collect_primary_roots()

    local direct = try_known_subpaths(primary_roots, KNOWN_SCREENS_SUBPATHS)
    if direct then return direct end

    for _, root in ipairs(primary_roots) do
        local found = search_arizona_screens(root)
        if found then return found end
    end

    local drive_roots = get_safe_drive_roots()

    local drive_direct = try_known_subpaths(drive_roots, KNOWN_SCREENS_SUBPATHS)
    if drive_direct then return drive_direct end

    for _, root in ipairs(drive_roots) do
        local found = search_arizona_screens(root)
        if found then return found end
    end

    return nil
end

local function find_chatlog_path()
    local roots = collect_primary_roots()

    local direct = try_known_subpaths(roots, CHATLOG_KNOWN_SUBPATHS)
    if direct then return direct end

    for _, root in ipairs(roots) do
        local found = search_file_by_name(root, "chatlog.txt")
        if found then return found end
    end

    local drive_roots = get_safe_drive_roots()
    for _, root in ipairs(drive_roots) do
        local found = search_file_by_name(root, "chatlog.txt")
        if found then return found end
    end

    return nil
end

local chatlog_path_resolved = nil
local chatlog_path_tried     = false

local function get_cached_chatlog_path()
    if chatlog_path_tried then
        return chatlog_path_resolved
    end
    chatlog_path_tried = true
    chatlog_path_resolved = find_chatlog_path()
    return chatlog_path_resolved
end

local function extract_screenshot_filename(text)
    local candidate = nil
    for word in text:gmatch("%S+") do
        local clean = word:gsub("[,:;%)%(%[%]\"']+$", "")
        local lower = clean:lower()
        if lower:match("%.jpg$") or lower:match("%.jpeg$") or lower:match("%.png$") then
            candidate = clean
        end
    end
    return candidate
end

local CHATLOG_POLL_INTERVAL = 100
local CHATLOG_MAX_WAIT      = 5000

local function wait_for_chatlog_screenshot_name(chatlog_path, baseline_size)
    local waited = 0
    while waited < CHATLOG_MAX_WAIT do
        wait(CHATLOG_POLL_INTERVAL)
        waited = waited + CHATLOG_POLL_INTERVAL

        local attr = lfs.attributes(chatlog_path)
        local size = attr and attr.size or 0
        if size > baseline_size then
            local file = io.open(chatlog_path, "rb")
            if file then
                file:seek("set", baseline_size)
                local new_content = file:read("*a")
                file:close()
                local name = extract_screenshot_filename(new_content or "")
                if name then
                    return name
                end
            end
        end
    end
    return nil
end

local function find_screens_folder_via_chatlog()
    local chatlog_path = find_chatlog_path()
    if not chatlog_path then return nil end

    local attr = lfs.attributes(chatlog_path)
    local baseline_size = attr and attr.size or 0

    setVirtualKeyDown(vkeys.VK_F8, true)
    wait(50)
    setVirtualKeyDown(vkeys.VK_F8, false)

    local filename = wait_for_chatlog_screenshot_name(chatlog_path, baseline_size)
    if not filename then return nil end

    local target_name_lower = filename:lower()
    local roots = collect_primary_roots()

    local found_file = nil
    for _, root in ipairs(roots) do
        found_file = search_file_by_name(root, target_name_lower)
        if found_file then break end
    end

    if not found_file then
        local drive_roots = get_safe_drive_roots()
        for _, root in ipairs(drive_roots) do
            found_file = search_file_by_name(root, target_name_lower)
            if found_file then break end
        end
    end

    if not found_file then return nil end

    local dated_subfolder = found_file:match("^(.*)\\[^\\]+$")
    if not dated_subfolder then return nil end
    local screens_root = dated_subfolder:match("^(.*)\\[^\\]+$")
    if not screens_root then return nil end

    if is_dir(screens_root) then
        return screens_root
    end
    return nil
end

local imgui_new = imgui.new

local screens_path_buf    = imgui_new.char[512](0)
local screens_path_error  = ""
local screens_path_open   = imgui_new.bool(false)
local screens_path_busy   = false
local screens_path_status = 'Идёт автопоиск, подождите...'
local screens_path_result = nil
local screens_root_folder = nil

local find_latest_screenshot_in
local verify_screens_folder

local function hexcol(hex, a)
    return imgui.ImVec4(
        tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255,
        a or 1.0
    )
end

local GREEN_BRIGHT = "05ff12"
local GREEN_MID    = "03e10d"
local GREEN_DARK   = "00a609"

local TAG_GRADIENT = {
    { "[", "05ff12" }, { "E", "05f911" }, { "v", "04f310" }, { "e", "04ed0f" },
    { "n", "03e70e" }, { "t", "03e10d" }, { "S", "02db0c" }, { "c", "02d50b" },
    { "a", "01cf0a" }, { "n", "01c909" }, { "]", "00a609" }
}

local function center_text(text, color)
    local avail_w = imgui.GetContentRegionAvail().x
    local text_w = imgui.CalcTextSize(text).x
    if text_w < avail_w then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail_w - text_w) / 2)
    end
    if color then
        imgui.TextColored(color, text)
    else
        imgui.Text(text)
    end
end

-- ==================== Планировщик событий /esp (аналог plan.html) ====================
-- Та же логика, что и на сайте: даты -5..+3 от сегодня, слоты по 20 минут,
-- бронирование/просмотр/удаление через тот же воркер (/plan, /plan/delete),
-- автор определяется сервером по HWID (см. /check-hwid и /plan).

local espl_open          = imgui_new.bool(false)
local espl_dates         = nil
local espl_selected_date = nil
local espl_schedule      = {}      -- ["HH:MM"] = { author = ..., title = ... }
local espl_loading       = false
local espl_load_error    = ""

local espl_modal_open        = false
local espl_modal_mode        = nil   -- "create" | "own" | "foreign"
local espl_modal_time         = nil
local espl_modal_title_buf   = imgui_new.char[128](0)
local espl_modal_view_author = ""
local espl_modal_view_title  = ""
local espl_modal_busy        = false
local espl_modal_error       = ""

-- Собственный "author" узнаём у сервера так же, как это делает plan.html
-- (через /check-hwid) — сравнивать напрямую с игровым ником нельзя, т.к.
-- author привязан к HWID в whitelist и может отличаться от текущего ника.
local espl_local_author     = nil
local espl_author_resolved  = false
local espl_author_resolving = false

local function resolve_espl_author(callback)
    if espl_author_resolved then
        if callback then callback(espl_local_author) end
        return
    end
    if espl_author_resolving then
        if callback then callback(nil) end
        return
    end

    local hwid = get_hwid()
    if not hwid then
        if callback then callback(nil) end
        return
    end

    espl_author_resolving = true
    lua_thread.create(function()
        local result = try_worker_urls(check_hwid_worker, function(url)
            return { hwid }
        end, 15000)

        if result and result.ok and result.author then
            espl_local_author = result.author
        end
        espl_author_resolved  = true
        espl_author_resolving = false

        if callback then callback(espl_local_author) end
    end)
end

local function espl_load_schedule(date_str, callback)
    lua_thread.create(function()
        local result = try_worker_urls(plan_fetch_worker, function(url)
            return { date_str }
        end, 15000)
        callback(result)
    end)
end

local function espl_apply_schedule_result(result)
    espl_loading = false
    if result and result.ok then
        local sched = {}
        for _, s in ipairs(result.slots or {}) do
            sched[s.time] = { author = s.author, title = s.title }
        end
        espl_schedule   = sched
        espl_load_error = ""
    else
        espl_load_error = u8("Не удалось загрузить расписание: ") .. tostring(result and result.err or "timeout")
    end
end

local function espl_select_date(ds)
    if ds == espl_selected_date then return end
    espl_selected_date = ds
    espl_schedule       = {}
    espl_loading        = true
    espl_load_error      = ""
    espl_load_schedule(ds, espl_apply_schedule_result)
end

-- ==================== Цвета авторов + вспомогательное для отрисовки ====================
-- Каждому автору присваивается стабильный (детерминированный) цвет на основе
-- хеша его имени — без localStorage, как в plan.html, но с тем же эффектом:
-- у одного и того же автора всегда один и тот же цвет.

local ESPL_AMBER = "d4a24e"
local ESPL_ELLIPSIS = u8("…")

local function espl_string_hash(str)
    local hash = 5381
    for i = 1, #str do
        hash = (hash * 33 + str:byte(i)) % 2147483647
    end
    return hash
end

local function espl_hsl_to_rgb(h, s, l)
    h = (h % 360) / 360
    local function hue2rgb(p, q, t)
        if t < 0 then t = t + 1 end
        if t > 1 then t = t - 1 end
        if t < 1 / 6 then return p + (q - p) * 6 * t end
        if t < 1 / 2 then return q end
        if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
        return p
    end
    if s == 0 then return l, l, l end
    local q = (l < 0.5) and (l * (1 + s)) or (l + s - l * s)
    local p = 2 * l - q
    return hue2rgb(p, q, h + 1 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1 / 3)
end

local espl_author_color_cache = {}

-- Возвращает набор ImVec4-цветов для конкретного автора: яркая обводка,
-- приглушённый фон, версии для наведения/приглушённого (прошедшего) состояния.
local function espl_author_colors(author)
    local key = (author and author ~= "") and author or "—"
    local cached = espl_author_color_cache[key]
    if cached then return cached end

    local hue = espl_string_hash(key) % 360
    local r, g, b = espl_hsl_to_rgb(hue, 0.65, 0.52)

    local colors = {
        border      = imgui.ImVec4(r, g, b, 1.0),
        border_dim  = imgui.ImVec4(r, g, b, 0.5),
        bg          = imgui.ImVec4(r * 0.30, g * 0.30, b * 0.30, 1.0),
        bg_hover    = imgui.ImVec4(r * 0.45, g * 0.45, b * 0.45, 1.0),
        bg_dim      = imgui.ImVec4(r * 0.20, g * 0.20, b * 0.20, 0.7),
        accent      = imgui.ImVec4(math.min(r * 1.35, 1), math.min(g * 1.35, 1), math.min(b * 1.35, 1), 1.0),
    }
    espl_author_color_cache[key] = colors
    return colors
end

-- В карточках слотов показываем только ник до "_" (полное "Nick_Name"
-- используется для цвета/сравнения/фильтрации "свой/чужой", но занимает
-- слишком много места на маленькой кнопке слота).
local function espl_short_nick(author)
    if not author or author == "" then return author end
    local nick = author:match("^([^_]+)")
    return nick or author
end

-- Обрезка строки по ширине с многоточием, безопасная для многобайтового UTF-8
-- (не режет символ Cyrillic пополам).
local function espl_truncate_to_width(text, max_width)
    if text == "" or imgui.CalcTextSize(text).x <= max_width then
        return text
    end

    local ellipsis_w = imgui.CalcTextSize(ESPL_ELLIPSIS).x
    local result = ""
    local i = 1
    while i <= #text do
        local b = text:byte(i)
        local clen = 1
        if b >= 0xF0 then clen = 4
        elseif b >= 0xE0 then clen = 3
        elseif b >= 0xC0 then clen = 2
        end

        local candidate = result .. text:sub(i, i + clen - 1)
        if imgui.CalcTextSize(candidate).x + ellipsis_w > max_width then
            break
        end
        result = candidate
        i = i + clen
    end

    if result == "" then return ESPL_ELLIPSIS end
    return result .. ESPL_ELLIPSIS
end

imgui.OnFrame(function() return espl_open[0] end, function()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 8))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 16))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.055, 0.075, 0.055, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.TitleBg, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(GREEN_BRIGHT))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))

    local imgui_io = imgui.GetIO()
    imgui.SetNextWindowPos(
        imgui.ImVec2(imgui_io.DisplaySize.x / 2, imgui_io.DisplaySize.y / 2),
        imgui.Cond.Appearing, imgui.ImVec2(0.5, 0.5)
    )

    imgui.Begin('##espl_window', espl_open,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.AlwaysAutoResize)

    if espl_dates then
        local today_ds = format_date_ymd(os.time() + MSK_OFFSET)
        for i, t in ipairs(espl_dates) do
            local ds        = format_date_ymd(t)
            local tbl       = os.date("!*t", t)
            local is_today  = ds == today_ds
            local is_active = ds == espl_selected_date
            local dow_text  = is_today and "Сегодня" or DOW_LABELS_RU[tbl.wday]
            local date_text = string.format("%02d.%02d", tbl.day, tbl.month)

            local tab_bg, tab_border, tab_text
            if is_active and is_today then
                tab_bg     = hexcol(ESPL_AMBER, 0.35)
                tab_border = hexcol(ESPL_AMBER, 1.0)
                tab_text   = imgui.ImVec4(1, 1, 1, 1)
            elseif is_active then
                tab_bg     = hexcol(GREEN_BRIGHT, 0.30)
                tab_border = hexcol(GREEN_BRIGHT, 1.0)
                tab_text   = imgui.ImVec4(1, 1, 1, 1)
            elseif is_today then
                tab_bg     = imgui.ImVec4(0.22, 0.17, 0.07, 1.0)
                tab_border = hexcol(ESPL_AMBER, 1.0)
                tab_text   = hexcol(ESPL_AMBER, 1.0)
            else
                tab_bg     = imgui.ImVec4(0.09, 0.13, 0.09, 1.0)
                tab_border = hexcol(GREEN_MID, 0.45)
                tab_text   = imgui.ImVec4(0.78, 0.85, 0.78, 1.0)
            end

            local tab_accent = is_today and ESPL_AMBER or GREEN_BRIGHT

            imgui.PushStyleColor(imgui.Col.Button, tab_bg)
            if espl_loading then
                imgui.PushStyleColor(imgui.Col.ButtonHovered, tab_bg)
                imgui.PushStyleColor(imgui.Col.ButtonActive, tab_bg)
            else
                imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(tab_accent, 0.45))
                imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(tab_accent, 0.55))
            end
            imgui.PushStyleColor(imgui.Col.Border, tab_border)
            imgui.PushStyleColor(imgui.Col.Text, tab_text)
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 2.0)

            local btn_size = imgui.ImVec2(78, 46)
            local btn_pos  = imgui.GetCursorScreenPos()

            local clicked = imgui.Button("##espl_date_" .. ds, btn_size)

            do
                local draw_list = imgui.GetWindowDrawList()
                local line1     = u8(dow_text)
                local line2     = date_text
                local line_h    = imgui.GetTextLineHeight()
                local w1        = imgui.CalcTextSize(line1).x
                local w2        = imgui.CalcTextSize(line2).x
                local start_y   = btn_pos.y + (btn_size.y - line_h * 2) / 2
                local color_u32 = imgui.ColorConvertFloat4ToU32(tab_text)

                draw_list:AddText(imgui.ImVec2(btn_pos.x + (btn_size.x - w1) / 2, start_y), color_u32, line1)
                draw_list:AddText(imgui.ImVec2(btn_pos.x + (btn_size.x - w2) / 2, start_y + line_h), color_u32, line2)
            end

            if clicked and not espl_loading then
                espl_select_date(ds)
            end

            imgui.PopStyleVar(1)
            imgui.PopStyleColor(5)

            if i % 9 ~= 0 then imgui.SameLine() end
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    do
        local status_text  = ""
        local status_color = hexcol(GREEN_BRIGHT)
        if espl_load_error ~= "" then
            status_text  = espl_load_error
            status_color = imgui.ImVec4(1, 0.35, 0.35, 1)
        elseif espl_loading then
            status_text  = u8("Загрузка расписания...")
        end

        if status_text ~= "" then
            center_text(status_text, status_color)
        else
            imgui.Dummy(imgui.ImVec2(0, imgui.GetTextLineHeight()))
        end
    end

    imgui.Spacing()

    local grid_locked = espl_loading or (espl_load_error ~= "")

    local slots     = espl_generate_time_slots()
    local cols      = 8
    local slot_w    = 84
    local slot_h    = 44
    local label_max_w = slot_w - 10

    local grid_w    = cols * slot_w + (cols - 1) * 8
    local avail_w   = imgui.GetContentRegionAvail().x
    local offset_x  = math.max((avail_w - grid_w) / 2, 0)
    local row_start_x = imgui.GetCursorPosX()

    for i, time in ipairs(slots) do
        if (i - 1) % cols == 0 then
            imgui.SetCursorPosX(row_start_x + offset_x)
        end

        local booking   = (not grid_locked) and espl_schedule[time] or nil
        local is_booked = booking ~= nil
        local is_past   = (not grid_locked) and espl_is_past(espl_selected_date, time) or false
        local disabled  = grid_locked or (is_past and not is_booked)

        local btn_bg, btn_bg_hover, btn_border, btn_text, border_size

        if is_booked then
            local c = espl_author_colors(booking.author)
            btn_bg       = is_past and c.bg_dim or c.bg
            btn_bg_hover = is_past and c.bg_dim or c.bg_hover
            btn_border   = is_past and c.border_dim or c.border
            btn_text     = is_past and imgui.ImVec4(0.85, 0.85, 0.85, 0.75) or imgui.ImVec4(1, 1, 1, 1)
            border_size  = 2.0
        elseif disabled then
            btn_bg       = imgui.ImVec4(0.08, 0.08, 0.08, 0.6)
            btn_bg_hover = btn_bg
            btn_border   = imgui.ImVec4(0.22, 0.22, 0.22, 0.5)
            btn_text     = imgui.ImVec4(0.45, 0.45, 0.45, 0.7)
            border_size  = 1.0
        else
            btn_bg       = imgui.ImVec4(0.10, 0.17, 0.10, 1.0)
            btn_bg_hover = imgui.ImVec4(0.16, 0.28, 0.16, 1.0)
            btn_border   = hexcol(GREEN_MID, 0.55)
            btn_text     = imgui.ImVec4(0.82, 0.92, 0.82, 1.0)
            border_size  = 1.0
        end

        imgui.PushStyleColor(imgui.Col.Button, btn_bg)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, btn_bg_hover)
        imgui.PushStyleColor(imgui.Col.ButtonActive, btn_bg_hover)
        imgui.PushStyleColor(imgui.Col.Border, btn_border)
        imgui.PushStyleColor(imgui.Col.Text, btn_text)
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, border_size)

        local label = time
        if is_booked then
            label = label .. "\n" .. espl_truncate_to_width(espl_short_nick(booking.author) or "", label_max_w)
        end

        local clicked = imgui.Button(label .. "##espl_slot_" .. time, imgui.ImVec2(slot_w, slot_h))

        imgui.PopStyleVar(1)
        imgui.PopStyleColor(5)

        if clicked and not disabled then
            espl_modal_time  = time
            espl_modal_error = ""

            if is_booked then
                local is_own = (espl_local_author ~= nil) and (booking.author == espl_local_author) and not is_past
                if is_own then
                    espl_modal_mode = "own"
                    espl_modal_title_buf[0] = 0
                    local title_bytes = booking.title or ""
                    ffi.copy(espl_modal_title_buf, title_bytes, math.min(#title_bytes, ffi.sizeof(espl_modal_title_buf) - 1))
                else
                    espl_modal_mode = "foreign"
                    espl_modal_view_author = booking.author or ""
                    espl_modal_view_title  = booking.title or ""
                end
            else
                espl_modal_mode = "create"
                espl_modal_title_buf[0] = 0
            end

            espl_modal_open = true
        end

        if i % cols ~= 0 then imgui.SameLine() end
    end

    imgui.End()

    imgui.PopStyleColor(8)
    imgui.PopStyleVar(4)
end)

imgui.OnFrame(function() return espl_modal_open end, function()
    local modal_booking = espl_schedule[espl_modal_time]
    local modal_author_colors = nil
    if espl_modal_mode == "foreign" then
        modal_author_colors = espl_author_colors(espl_modal_view_author)
    elseif modal_booking then
        modal_author_colors = espl_author_colors(modal_booking.author)
    end
    local modal_border = modal_author_colors and modal_author_colors.border or hexcol(GREEN_MID)

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 2.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(18, 16))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 10))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.05, 0.08, 0.05, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, modal_border)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))

    local imgui_io = imgui.GetIO()
    imgui.SetNextWindowPos(
        imgui.ImVec2(imgui_io.DisplaySize.x / 2, imgui_io.DisplaySize.y / 2),
        imgui.Cond.Always, imgui.ImVec2(0.5, 0.5)
    )

    -- Модалка обязана быть поверх основного окна планировщика всегда, а не
    -- только в момент открытия: ImGui сортирует окна по z-order на основе
    -- фокуса, и клик по основному окну (сквозь промежутки между слотами,
    -- скролл и т.п.) мог перетащить фокус на него и утопить модалку под
    -- ним. Поэтому каждый кадр, пока модалка открыта, принудительно
    -- отдаём ей фокус до вызова Begin — тогда она гарантированно рисуется
    -- последней (сверху) и не может провалиться под основное окно.
    imgui.SetNextWindowFocus()

    imgui.Begin('##espl_modal_window', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoSavedSettings +
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize)

    local MODAL_CONTENT_W = 300

    center_text(u8(tostring(espl_selected_date) .. " · " .. tostring(espl_modal_time)), hexcol(GREEN_BRIGHT))
    imgui.Spacing()

    if espl_modal_mode == "foreign" then
        imgui.Text(u8("Автор:"))
        imgui.SameLine()
        do
            local draw_list   = imgui.GetWindowDrawList()
            local swatch_pos  = imgui.GetCursorScreenPos()
            local swatch_size = 12
            draw_list:AddRectFilled(
                swatch_pos,
                imgui.ImVec2(swatch_pos.x + swatch_size, swatch_pos.y + swatch_size),
                imgui.ColorConvertFloat4ToU32(modal_author_colors.accent), 3
            )
            imgui.Dummy(imgui.ImVec2(swatch_size + 4, swatch_size))
        end
        imgui.SameLine(0, 4)
        imgui.TextColored(modal_author_colors.accent, espl_modal_view_author)

        imgui.Spacing()
        imgui.Text(u8("Название:"))
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + MODAL_CONTENT_W)
        imgui.TextWrapped(espl_modal_view_title)
        imgui.PopTextWrapPos()
    else
        imgui.PushItemWidth(MODAL_CONTENT_W)
        imgui.InputText('##espl_title_input', espl_modal_title_buf, ffi.sizeof(espl_modal_title_buf))
        imgui.PopItemWidth()
    end

    if espl_modal_error ~= "" then
        imgui.Spacing()
        center_text(espl_modal_error, imgui.ImVec4(1, 0.35, 0.35, 1))
    end

    imgui.Spacing()

    if espl_modal_busy then
        center_text(u8("Отправка..."), hexcol(GREEN_BRIGHT))
    elseif espl_modal_mode == "foreign" then
        if imgui.Button(u8("Закрыть"), imgui.ImVec2(MODAL_CONTENT_W, 32)) then
            espl_modal_open = false
        end
    else
        local avail      = MODAL_CONTENT_W
        local gap        = 8
        local has_delete = espl_modal_mode == "own"
        local btn_count  = has_delete and 3 or 2
        local btn_w      = (avail - gap * (btn_count - 1)) / btn_count

        if imgui.Button(u8("Сохранить"), imgui.ImVec2(btn_w, 32)) then
            local title = ffi.string(espl_modal_title_buf)
            title = title:gsub('^%s+', ''):gsub('%s+$', '')

            if title == "" then
                espl_modal_error = u8("Введите название мероприятия")
            else
                local hwid = get_hwid()
                if not hwid then
                    espl_modal_error = u8("HWID ещё не определён")
                else
                    espl_modal_busy = true
                    local time = espl_modal_time
                    local date = espl_selected_date

                    lua_thread.create(function()
                        local result = try_worker_urls(plan_save_worker, function(url)
                            return { hwid, date, time, title }
                        end, 15000)
                        espl_modal_busy = false

                        if result and result.ok then
                            espl_schedule[time] = { author = result.author, title = result.title }
                            espl_modal_open = false
                        else
                            local err = result and result.err or "timeout"
                            espl_modal_error = u8("Ошибка сохранения: ") .. tostring(err)
                        end
                    end)
                end
            end
        end

        imgui.SameLine(0, gap)

        if has_delete then
            if imgui.Button(u8("Удалить"), imgui.ImVec2(btn_w, 32)) then
                local hwid = get_hwid()
                if not hwid then
                    espl_modal_error = u8("HWID ещё не определён")
                else
                    espl_modal_busy = true
                    local time = espl_modal_time
                    local date = espl_selected_date

                    lua_thread.create(function()
                        local result = try_worker_urls(plan_delete_worker, function(url)
                            return { hwid, date, time }
                        end, 15000)
                        espl_modal_busy = false

                        if result and result.ok then
                            espl_schedule[time] = nil
                            espl_modal_open = false
                        else
                            local err = result and result.err or "timeout"
                            espl_modal_error = u8("Ошибка удаления: ") .. tostring(err)
                        end
                    end)
                end
            end
            imgui.SameLine(0, gap)
        end

        if imgui.Button(u8("Отмена"), imgui.ImVec2(btn_w, 32)) then
            espl_modal_open = false
        end
    end

    imgui.End()

    imgui.PopStyleColor(5)
    imgui.PopStyleVar(5)
end)

-- ==================== Всплывающее уведомление снизу экрана ====================
-- Тост с анимацией
local toast_visible = imgui_new.bool(false)
local toast_state = {
    text       = "",
    color      = nil,
    anim_time  = 0,      -- время анимации (0 до 1)
    start_tick = 0,      -- время начала показа
    closing    = false   -- флаг закрытия
}

local TOAST_ANIM_DURATION = 0.3  -- длительность анимации появления в секундах
local TOAST_CLOSE_DURATION = 0.25 -- длительность анимации закрытия в секундах

local function show_toast(text, color_hex)
    -- Не показываем тост, если открыто окно настроек
    if screens_path_open[0] then
        return
    end
    
    toast_state.text    = text
    toast_state.color   = color_hex and hexcol(color_hex) or hexcol(GREEN_BRIGHT)
    toast_state.closing = false
    
    -- Если окно уже показывается, просто обновляем текст без перезапуска анимации
    if not toast_visible[0] then
        toast_state.anim_time  = 0
        toast_state.start_tick = os.clock()
        toast_visible[0]       = true
    end
end

local function hide_toast()
    if toast_visible[0] and not toast_state.closing then
        toast_state.closing    = true
        toast_state.start_tick = os.clock()
        toast_state.anim_time  = 0
    end
end

-- ==================== Всплывающее уведомление для /ess ====================
local ess_toast_visible = imgui_new.bool(false)
local ess_toast_state = {
    text       = "",
    color      = nil,
    anim_time  = 0,
    start_tick = 0,
    closing    = false
}

local ESS_TOAST_ANIM_DURATION = 0.3
local ESS_TOAST_CLOSE_DURATION = 0.25

local function show_ess_toast(text, color_hex)
    if screens_path_open[0] then
        return
    end
    
    ess_toast_state.text    = text
    ess_toast_state.color   = color_hex and hexcol(color_hex) or hexcol(GREEN_BRIGHT)
    ess_toast_state.closing = false
    
    if not ess_toast_visible[0] then
        ess_toast_state.anim_time  = 0
        ess_toast_state.start_tick = os.clock()
        ess_toast_visible[0]       = true
    end
end

local function hide_ess_toast()
    if ess_toast_visible[0] and not ess_toast_state.closing then
        ess_toast_state.closing    = true
        ess_toast_state.start_tick = os.clock()
        ess_toast_state.anim_time  = 0
    end
end

-- Уменьшенный размер окна без иконок
local TOAST_PAD = 12

imgui.OnFrame(function() return toast_visible[0] and not screens_path_open[0] end, function()
    -- Обновляем время анимации
    local elapsed = os.clock() - toast_state.start_tick
    
    local anim_progress
    if toast_state.closing then
        -- Анимация закрытия
        toast_state.anim_time = math.min(elapsed / TOAST_CLOSE_DURATION, 1.0)
        
        -- Если анимация закрытия завершена, скрываем окно
        if toast_state.anim_time >= 1.0 then
            toast_visible[0] = false
            toast_state.closing = false
            return
        end
        
        -- Инвертируем прогресс для закрытия (от 1 до 0)
        anim_progress = 1.0 - toast_state.anim_time
    else
        -- Анимация открытия
        toast_state.anim_time = math.min(elapsed / TOAST_ANIM_DURATION, 1.0)
        anim_progress = toast_state.anim_time
    end
    
    -- Функция easing для плавной анимации (ease-out для открытия, ease-in для закрытия)
    local function ease_out_cubic(t)
        return 1 - math.pow(1 - t, 3)
    end
    
    local function ease_in_cubic(t)
        return t * t * t
    end
    
    local eased_progress
    if toast_state.closing then
        eased_progress = ease_in_cubic(anim_progress)
    else
        eased_progress = ease_out_cubic(anim_progress)
    end
    
    -- Увеличенное окно для большого текста
    local win_w, win_h = 160, 40
    local imgui_io = imgui.GetIO()
    local screen_w = imgui_io.DisplaySize.x
    local screen_h = imgui_io.DisplaySize.y

    -- Опускаем почти к самому низу экрана (оставляем только 8 пикселей от края)
    local final_pos_y = screen_h - win_h - 8
    
    -- Анимация: окно появляется/исчезает снизу
    local start_offset = 30  -- начальное смещение вниз
    local pos_y = final_pos_y + start_offset * (1 - eased_progress)
    
    -- Анимация прозрачности
    local alpha = 0.97 * eased_progress

    imgui.SetNextWindowPos(imgui.ImVec2(screen_w / 2, pos_y), imgui.Cond.Always, imgui.ImVec2(0.5, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(win_w, win_h), imgui.Cond.Always)
    imgui.SetNextWindowBgAlpha(alpha)

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 18)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(10, 8))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.0, 0.0, 0.0, 0.0))  -- прозрачный фон
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(
        hexcol(GREEN_MID).x,
        hexcol(GREEN_MID).y,
        hexcol(GREEN_MID).z,
        eased_progress
    ))

    imgui.Begin('##es_toast', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove +
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoFocusOnAppearing +
        imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav)

    -- Рисуем внутреннюю рамку для создания промежутка между фоном и обводкой
    local draw_list = imgui.GetWindowDrawList()
    local win_pos = imgui.GetWindowPos()
    local win_size = imgui.GetWindowSize()
    local gap = 3  -- промежуток в пикселях
    local inner_rounding = 15  -- скругление внутренней рамки (меньше чем внешнее)
    
    -- Рисуем внутренний скругленный прямоугольник (фон)
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x + gap, win_pos.y + gap),
        imgui.ImVec2(win_pos.x + win_size.x - gap, win_pos.y + win_size.y - gap),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.06, 0.09, 0.06, alpha)),
        inner_rounding
    )

    imgui.Dummy(imgui.ImVec2(0, 4))

    -- Тост без градиентного тега - просто текст

    imgui.Spacing()

    -- Крупный шрифт для тоста (настоящий шрифт нужного размера, без растяжки)
    local using_toast_font = toast_font ~= nil
    if using_toast_font then
        imgui.PushFont(toast_font)
    end

    -- Упрощенная отрисовка текста без иконок
    local text = toast_state.text
    local text_color = toast_state.color
    local win_size = imgui.GetWindowSize()
    local line_h = imgui.GetTextLineHeight()
    
    -- Центрируем текст по вертикали
    imgui.SetCursorPosY((win_size.y - line_h) / 2)
    
    -- Центрируем текст по горизонтали
    local text_w = imgui.CalcTextSize(text).x
    local avail_w = win_size.x - (TOAST_PAD * 2)
    if text_w < avail_w then
        imgui.SetCursorPosX(TOAST_PAD + (avail_w - text_w) / 2)
    else
        imgui.SetCursorPosX(TOAST_PAD)
    end
    
    imgui.PushTextWrapPos(win_size.x - TOAST_PAD)
    
    if text_color then
        -- Применяем альфа-канал к цвету текста для анимации
        imgui.TextColored(imgui.ImVec4(
            text_color.x,
            text_color.y,
            text_color.z,
            eased_progress
        ), text)
    else
        imgui.TextColored(imgui.ImVec4(1, 1, 1, eased_progress), text)
    end
    
    imgui.PopTextWrapPos()

    if using_toast_font then
        imgui.PopFont()
    end

    imgui.End()

    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end).HideCursor = true  -- Отключаем курсор мыши для тоста

-- ==================== Окно для отправки отчёта /ess ====================
imgui.OnFrame(function() return ess_toast_visible[0] and not screens_path_open[0] end, function()
    local elapsed = os.clock() - ess_toast_state.start_tick
    
    local anim_progress
    if ess_toast_state.closing then
        ess_toast_state.anim_time = math.min(elapsed / ESS_TOAST_CLOSE_DURATION, 1.0)
        
        if ess_toast_state.anim_time >= 1.0 then
            ess_toast_visible[0] = false
            ess_toast_state.closing = false
            return
        end
        
        anim_progress = 1.0 - ess_toast_state.anim_time
    else
        ess_toast_state.anim_time = math.min(elapsed / ESS_TOAST_ANIM_DURATION, 1.0)
        anim_progress = ess_toast_state.anim_time
    end
    
    local function ease_out_cubic(t)
        return 1 - math.pow(1 - t, 3)
    end
    
    local function ease_in_cubic(t)
        return t * t * t
    end
    
    local eased_progress
    if ess_toast_state.closing then
        eased_progress = ease_in_cubic(anim_progress)
    else
        eased_progress = ease_out_cubic(anim_progress)
    end
    
    local win_w, win_h = 200, 40
    local imgui_io = imgui.GetIO()
    local screen_w = imgui_io.DisplaySize.x
    local screen_h = imgui_io.DisplaySize.y

    local final_pos_y = screen_h - win_h - 8
    local start_offset = 30
    local pos_y = final_pos_y + start_offset * (1 - eased_progress)
    local alpha = 0.97 * eased_progress

    imgui.SetNextWindowPos(imgui.ImVec2(screen_w / 2, pos_y), imgui.Cond.Always, imgui.ImVec2(0.5, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(win_w, win_h), imgui.Cond.Always)
    imgui.SetNextWindowBgAlpha(alpha)

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 18)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(10, 8))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.0, 0.0, 0.0, 0.0))  -- прозрачный фон
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(
        hexcol(GREEN_MID).x,
        hexcol(GREEN_MID).y,
        hexcol(GREEN_MID).z,
        eased_progress
    ))

    imgui.Begin('##ess_toast', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove +
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoFocusOnAppearing +
        imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav)

    -- Рисуем внутреннюю рамку для создания промежутка между фоном и обводкой
    local draw_list = imgui.GetWindowDrawList()
    local win_pos = imgui.GetWindowPos()
    local win_size = imgui.GetWindowSize()
    local gap = 3  -- промежуток в пикселях
    local inner_rounding = 15  -- скругление внутренней рамки (меньше чем внешнее)
    
    -- Рисуем внутренний скругленный прямоугольник (фон)
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x + gap, win_pos.y + gap),
        imgui.ImVec2(win_pos.x + win_size.x - gap, win_pos.y + win_size.y - gap),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.06, 0.09, 0.06, alpha)),
        inner_rounding
    )

    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Spacing()

    local using_toast_font = toast_font ~= nil
    if using_toast_font then
        imgui.PushFont(toast_font)
    end

    local text = ess_toast_state.text
    local text_color = ess_toast_state.color
    local win_size = imgui.GetWindowSize()
    local line_h = imgui.GetTextLineHeight()
    
    imgui.SetCursorPosY((win_size.y - line_h) / 2)
    
    local text_w = imgui.CalcTextSize(text).x
    local avail_w = win_size.x - (TOAST_PAD * 2)
    if text_w < avail_w then
        imgui.SetCursorPosX(TOAST_PAD + (avail_w - text_w) / 2)
    else
        imgui.SetCursorPosX(TOAST_PAD)
    end
    
    imgui.PushTextWrapPos(win_size.x - TOAST_PAD)
    
    if text_color then
        imgui.TextColored(imgui.ImVec4(
            text_color.x,
            text_color.y,
            text_color.z,
            eased_progress
        ), text)
    else
        imgui.TextColored(imgui.ImVec4(1, 1, 1, eased_progress), text)
    end
    
    imgui.PopTextWrapPos()

    if using_toast_font then
        imgui.PopFont()
    end

    imgui.End()

    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end).HideCursor = true  -- Отключаем курсор мыши для ess тоста

local ok_cdef_ansi = pcall(function()
    ffi.cdef[[
        int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
                                 const char* lpMultiByteStr, int cbMultiByte,
                                 wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags,
                                 const wchar_t* lpWideCharStr, int cchWideChar,
                                 char* lpMultiByteStr, int cbMultiByte,
                                 const char* lpDefaultChar, int* lpUsedDefaultChar);
    ]]
end)

local function utf8_to_ansi(str)
    if not str or str == "" then return str end

    local ok_load, kernel32 = pcall(ffi.load, "kernel32")
    if not ok_load or not kernel32 then return str end

    local CP_UTF8 = 65001
    local CP_ACP  = 0

    local ok1, wlen = pcall(kernel32.MultiByteToWideChar, CP_UTF8, 0, str, -1, nil, 0)
    if not ok1 or not wlen or wlen <= 0 then return str end

    local wbuf = ffi.new("wchar_t[?]", wlen)
    kernel32.MultiByteToWideChar(CP_UTF8, 0, str, -1, wbuf, wlen)

    local ok2, alen = pcall(kernel32.WideCharToMultiByte, CP_ACP, 0, wbuf, -1, nil, 0, nil, nil)
    if not ok2 or not alen or alen <= 0 then return str end

    local abuf = ffi.new("char[?]", alen)
    kernel32.WideCharToMultiByte(CP_ACP, 0, wbuf, -1, abuf, alen, nil, nil)

    return ffi.string(abuf, alen - 1)
end

imgui.OnFrame(function() return screens_path_open[0] end, function()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 6)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 4)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 16))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 10))

    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.09, 0.06, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.TitleBg, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.10, 0.14, 0.10, 1))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.12, 0.20, 0.12, 1))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0.14, 0.24, 0.14, 1))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(GREEN_BRIGHT))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))

    local imgui_io = imgui.GetIO()
    imgui.SetNextWindowPos(
        imgui.ImVec2(imgui_io.DisplaySize.x / 2, imgui_io.DisplaySize.y / 2),
        imgui.Cond.Always,
        imgui.ImVec2(0.5, 0.5)
    )

    local window_height = (screens_path_error ~= "") and 242 or 218
    imgui.SetNextWindowSize(imgui.ImVec2(520, window_height), imgui.Cond.Always)
    imgui.Begin(u8('Настройка EventScan'), nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoSavedSettings)
    center_text(u8('Не найдена папка со скриншотами (arizona\\screens).'))
    center_text(u8('Вставьте путь, нажмите "Обзор..." или "Авто" для автопоиска.'))
    center_text(u8('Путь к папке:'), hexcol(GREEN_BRIGHT))
    imgui.PushItemWidth(-1)
    imgui.InputText('##screens_path_input', screens_path_buf, ffi.sizeof(screens_path_buf))
    imgui.PopItemWidth()

    if screens_path_error ~= "" then
        center_text(u8(screens_path_error), imgui.ImVec4(1, 0.35, 0.35, 1))
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    if screens_path_busy then
        center_text(u8(screens_path_status), hexcol(GREEN_BRIGHT))
    else

        local gap = 10
        local avail_w = imgui.GetContentRegionAvail().x
        local btn_w = (avail_w - gap * 2) / 3

        if imgui.Button(u8('Готово'), imgui.ImVec2(btn_w, 34)) then
            local path = ffi.string(screens_path_buf)
            path = path:gsub('^%s+', ''):gsub('%s+$', ''):gsub('"', '')

            path = utf8_to_ansi(path)
            if path == "" then
                screens_path_error = "Введите путь к папке"
            elseif not is_dir(path) then
                screens_path_error = "Такой папки не существует"
            else
                screens_path_error = ""
                screens_path_result = { mode = "manual", path = path }
            end
        end
        imgui.SameLine(0, gap)
        if imgui.Button(u8('Обзор...'), imgui.ImVec2(btn_w, 34)) then
            screens_path_error = ""
            screens_path_result = { mode = "browse" }
        end
        imgui.SameLine(0, gap)
        if imgui.Button(u8('Авто'), imgui.ImVec2(btn_w, 34)) then
            screens_path_error = ""
            screens_path_result = { mode = "auto" }
        end
    end

    imgui.End()

    imgui.PopStyleColor(11)
    imgui.PopStyleVar(4)
end)

local function resolve_screens_root(callback)
    local cached = load_cached_screens_root()
    if cached then
        callback(cached)
        return
    end

    screens_path_buf[0]  = 0
    screens_path_error   = ""
    screens_path_busy    = false
    screens_path_result  = nil
    screens_path_open[0] = true

    lua_thread.create(function()
        while true do
            while screens_path_result == nil do
                wait(50)
            end

            local action = screens_path_result
            screens_path_result = nil

            if action.mode == "manual" then

                screens_path_error  = ""
                screens_path_busy   = true
                screens_path_status = 'Проверяю папку — жду тестовый скриншот (F8)...'

                local ok = verify_screens_folder(action.path)
                screens_path_busy = false

                if ok then
                    screens_path_open[0] = false
                    save_cached_screens_root(action.path)
                    es_msg("Папка подтверждена — тестовый скриншот найден!")
                    callback(action.path)
                    return
                else
                    screens_path_error = "Тестовый скриншот не появился в этой папке за отведённое время. Проверьте путь и попробуйте снова."

                end
            elseif action.mode == "browse" then

                screens_path_error   = ""
                screens_path_busy    = true
                screens_path_status  = 'Открыт системный диалог выбора папки...'

                local browse_channel = effil.channel()
                local browse_thr = effil.thread(browse_folder_worker)(
                    browse_channel, u8('Выберите папку arizona\\screens')
                )
                active_threads[#active_threads+1] = browse_thr

                local browse_result = wait_for_channel(browse_channel, 120000)

                if not browse_result or not browse_result.ok then
                    screens_path_busy = false
                    if browse_result and browse_result.err == "cancelled" then

                    else
                        screens_path_error = "Не удалось открыть диалог выбора папки. Введите путь вручную."
                    end
                else
                    local chosen_path = browse_result.path
                    screens_path_buf[0] = 0
                    ffi.copy(screens_path_buf, chosen_path, math.min(#chosen_path, ffi.sizeof(screens_path_buf) - 1))

                    if not is_dir(chosen_path) then
                        screens_path_busy = false
                        screens_path_error = "Выбранная папка недоступна."
                    else
                        screens_path_status = 'Проверяю папку — жду тестовый скриншот (F8)...'

                        local ok = verify_screens_folder(chosen_path)
                        screens_path_busy = false

                        if ok then
                            screens_path_open[0] = false
                            save_cached_screens_root(chosen_path)
                            es_msg("Папка подтверждена — тестовый скриншот найден!")
                            callback(chosen_path)
                            return
                        else
                            screens_path_error = "Тестовый скриншот не появился в этой папке за отведённое время. Проверьте путь и попробуйте снова."
                        end
                    end
                end
            else
                screens_path_busy   = true
                screens_path_status = 'Идёт автопоиск, подождите...'

                local found = find_screens_folder_everywhere()

                if not found then
                    screens_path_status = 'Не нашёл папку напрямую — жду сообщение о сохранении скриншота в чате (F8)...'
                    found = find_screens_folder_via_chatlog()
                end

                if found then

                    screens_path_status = 'Нашёл! Проверяю папку — жду тестовый скриншот (F8)...'
                    local ok = verify_screens_folder(found)
                    screens_path_busy = false

                    if ok then
                        screens_path_open[0] = false
                        save_cached_screens_root(found)
                        es_msg("Нашёл и подтвердил тестовым скриншотом! Запомню, чтобы не искать заново!")
                        callback(found)
                        return
                    else
                        screens_path_error = "Папка найдена автопоиском, но тестовый скриншот в ней не появился. Укажите путь вручную."
                    end
                else
                    screens_path_busy = false
                    screens_path_error = "Не найдено автоматически (включая поиск через чат-лог). Укажите путь вручную."

                end
            end
        end
    end)
end

find_latest_screenshot_in = function(root_folder)
    local latest_subfolder = nil
    local max_folder_time = 0
    for file_name in lfs.dir(root_folder) do
        if file_name ~= "." and file_name ~= ".." then
            local full_sub_path = root_folder .. "\\" .. file_name
            if is_dir(full_sub_path) then
                local attr = lfs.attributes(full_sub_path)
                if attr and attr.modification > max_folder_time then
                    max_folder_time = attr.modification
                    latest_subfolder = full_sub_path
                end
            end
        end
    end
    if not latest_subfolder then return nil, "subfolder_not_found" end

    local target_file = nil
    local max_file_time = 0
    for file_name in lfs.dir(latest_subfolder) do
        if file_name:find("%.jpg$") or file_name:find("%.png$") or file_name:find("%.jpeg$") then
            local full_file_path = latest_subfolder .. "\\" .. file_name
            local attr = lfs.attributes(full_file_path)
            if attr and attr.mode == "file" and attr.modification > max_file_time then
                max_file_time = attr.modification
                target_file = full_file_path
            end
        end
    end
    if not target_file then return nil, "file_not_found" end

    return target_file, nil, max_file_time
end

local FILE_STABLE_POLL_INTERVAL = 100
local FILE_STABLE_MAX_WAIT      = 3000

local function wait_until_file_stable(path)
    local last_size = -1
    local stable_hits = 0
    local waited = 0

    while waited < FILE_STABLE_MAX_WAIT do
        local attr = lfs.attributes(path)
        local size = attr and attr.size or nil

        if size and size > 0 then
            if size == last_size then
                stable_hits = stable_hits + 1
                if stable_hits >= 2 then
                    return true
                end
            else
                stable_hits = 0
                last_size = size
            end
        end

        wait(FILE_STABLE_POLL_INTERVAL)
        waited = waited + FILE_STABLE_POLL_INTERVAL
    end

    return last_size > 0
end

local VERIFY_SCREENSHOT_POLL_INTERVAL = 100
local VERIFY_SCREENSHOT_MAX_WAIT      = 5000

verify_screens_folder = function(path)
    local _, _, baseline_time = find_latest_screenshot_in(path)
    baseline_time = baseline_time or 0

    setVirtualKeyDown(vkeys.VK_F8, true)
    wait(50)
    setVirtualKeyDown(vkeys.VK_F8, false)

    local waited = 0
    while waited < VERIFY_SCREENSHOT_MAX_WAIT do
        wait(VERIFY_SCREENSHOT_POLL_INTERVAL)
        waited = waited + VERIFY_SCREENSHOT_POLL_INTERVAL

        local candidate, _, candidate_time = find_latest_screenshot_in(path)
        if candidate and (candidate_time or 0) > baseline_time then
            wait_until_file_stable(candidate)
            return true
        end
    end

    return false
end

local SCREENSHOT_POLL_INTERVAL = 100
local SCREENSHOT_MAX_WAIT      = 4000

local function capture_and_upload_screenshot(callback)

    if not screens_root_folder then
        show_toast(u8("Папка не настроена"), "FFAA00")
        return callback(nil)
    end
    if not get_hwid() then
        show_toast(u8("Hwid"), "FFAA00")
        return callback(nil)
    end
    local root_folder = screens_root_folder

    lua_thread.create(function()
        local _, baseline_err, baseline_time = find_latest_screenshot_in(root_folder)
        baseline_time = baseline_time or 0

        local chatlog_path = get_cached_chatlog_path()
        local chatlog_baseline_size = nil
        if chatlog_path then
            local attr = lfs.attributes(chatlog_path)
            chatlog_baseline_size = attr and attr.size or 0
        end

        setVirtualKeyDown(vkeys.VK_F8, true)
        wait(50)
        setVirtualKeyDown(vkeys.VK_F8, false)

        local target_file
        local chat_notice_shown = false
        local waited = 0
        while waited < SCREENSHOT_MAX_WAIT do
            wait(SCREENSHOT_POLL_INTERVAL)
            waited = waited + SCREENSHOT_POLL_INTERVAL

            if not chat_notice_shown and chatlog_path and chatlog_baseline_size then
                local attr = lfs.attributes(chatlog_path)
                local size = attr and attr.size or 0
                if size > chatlog_baseline_size then
                    local file = io.open(chatlog_path, "rb")
                    if file then
                        file:seek("set", chatlog_baseline_size)
                        local new_content = file:read("*a")
                        file:close()
                        if new_content and extract_screenshot_filename(new_content) then
                            chat_notice_shown = true
                        end
                    end
                end
            end

            local candidate, _, candidate_time = find_latest_screenshot_in(root_folder)
            if candidate and (candidate_time or 0) > baseline_time then
                target_file = candidate
                break
            end
        end

        if not target_file then
            show_toast(u8("Ошибка!"), "FF4444")
            wait(2000)
            hide_toast()
            return callback(nil)
        end

        wait_until_file_stable(target_file)

        local file = nil
        for attempt = 1, 4 do
            file = io.open(target_file, "rb")
            if file then break end
            wait(150)
        end
        if not file then
            show_toast(u8("Ошибка!"), "FF4444")
            wait(2000)
            hide_toast()
            return callback(nil)
        end
        local binary_data = file:read("*a")
        file:close()

        show_toast(u8("Сканирую..."), GREEN_BRIGHT)

        local hwid_value = get_hwid()
        local result = try_worker_urls(screenshot_upload_worker, function(url)
            return { WORKER_TOKEN, binary_data, hwid_value }
        end, 20000)
        if result and result.ok then
            show_toast(u8("Готово!"), GREEN_BRIGHT)
            wait(2000)
            hide_toast()
            callback(result.url)
        else
            local err = result and result.err or "timeout"
            if is_hwid_error(err) then
                copy_to_clipboard(get_hwid() or "UNKNOWN")
                show_toast(u8("Hwid"), "FF4444")
                wait(2000)
                hide_toast()
            else
                show_toast(u8("Ошибка!"), "FF4444")
                wait(2000)
                hide_toast()
            end
            callback(nil)
        end
    end)
end

local function send_report_to_d1(payload_json, on_done)
    local hwid = get_hwid()
    if not hwid then
        es_msg("HWID ещё определяется в фоне — попробуй отправить отчёт через пару секунд.", "FFAA00")
        if on_done then on_done(false) end
        return
    end

    show_ess_toast(u8("Отправка..."), GREEN_BRIGHT)

    lua_thread.create(function()
        local result = try_worker_urls(d1_report_worker, function(url)
            return { WORKER_TOKEN, payload_json, hwid }
        end, 20000)
        if result and result.ok then
            show_ess_toast(u8("Готово!"), GREEN_BRIGHT)
            wait(2000)
            hide_ess_toast()
            es_msg("Отчёт успешно сохранён в базу данных!")
            if on_done then on_done(true) end
        else
            local err = result and result.err or "timeout"
            if is_hwid_error(err) then
                show_ess_toast(u8("Ошибка HWID!"), "FF4444")
                wait(2000)
                hide_ess_toast()
                notify_hwid_denied()
            else
                show_ess_toast(u8("Ошибка!"), "FF4444")
                wait(2000)
                hide_ess_toast()
                es_msg("Ошибка сохранения отчёта: " .. tostring(err), "FF4444")
            end
            if on_done then on_done(false) end
        end
    end)
end

local function fetch_last_report_from_d1(on_done)
    lua_thread.create(function()
        local result = try_worker_urls(d1_last_report_worker, function(url)
            return { WORKER_TOKEN }
        end, 15000)
        if result and result.ok then
            on_done(result.date)
        else
            on_done(nil, result and result.err or "timeout")
        end
    end)
end

local function download_and_install_update()
    if update_in_progress then return end
    update_in_progress = true

    es_msg("Скачиваю обновление...")

    lua_thread.create(function()
        local channel = effil.channel()
        local thr = effil.thread(update_download_worker)(channel, UPDATE_DOWNLOAD_URL)
        active_threads[#active_threads+1] = thr

        local result = wait_for_channel(channel, 30000)
        update_in_progress = false

        if not result or not result.ok or not result.data then
            es_msg("Не удалось скачать обновление: " .. tostring(result and result.err or "timeout"), "FF4444")
            return
        end

        local script_path = thisScript().path
        local tmp_path = script_path .. ".update"

        local file = io.open(tmp_path, "wb")
        if not file then
            es_msg("Не удалось создать временный файл для обновления!", "FF4444")
            return
        end
        file:write(result.data)
        file:close()

        local old_path = script_path .. ".old"
        os.remove(old_path)
        local renamed_old = os.rename(script_path, old_path)
        if not renamed_old then
            os.remove(tmp_path)
            es_msg("Не удалось заменить файл скрипта (возможно, он занят). Обновление отменено.", "FF4444")
            return
        end

        local renamed_new = os.rename(tmp_path, script_path)
        if not renamed_new then
            os.rename(old_path, script_path)
            es_msg("Не удалось завершить замену файла скрипта. Обновление отменено.", "FF4444")
            return
        end

        update_available = false
        es_msg("Обновление успешно установлено! Перезапустите скрипт (перезагрузите MoonLoader или игру), чтобы применить его.")
    end)
end

local function check_for_update()
    lua_thread.create(function()
        local channel = effil.channel()
        local thr = effil.thread(version_check_worker)(channel, VERSION_CHECK_URL)
        active_threads[#active_threads+1] = thr

        local result = wait_for_channel(channel, 15000)
        if result and result.ok and result.version then
            if result.version ~= SCRIPT_VERSION then
                update_available      = true
                update_remote_version = result.version
                es_msg(string.format(
                    "Доступно обновление ({FFFF00}%s{FFFFFF} -> {FFFF00}%s{FFFFFF}). Начинаю автоматическую установку...",
                    SCRIPT_VERSION, result.version
                ), "FFFFFF")
                download_and_install_update()
            end
        end
    end)
end

function main()
    while not isSampAvailable() do wait(100) end

    resolve_screens_root(function(path)
        screens_root_folder = path
    end)

    resolve_hwid()
    resolve_espl_author()
    check_for_update()

    es_msg("{FFFF00}/es {FFFFFF}(добавить скан), {FFFF00}")
    es_msg("{FFFF00}/ess Название Ник_Победителя {FFFFFF}(Отправить отчет)")
    es_msg("{FFFF00}/eslast {FFFFFF}(время с последнего отчёта)")
    es_msg("{FFFF00}/esr {FFFFFF}(открыть CRM-дашборд твоих отчётов)")
    es_msg("{FFFF00}/esp {FFFFFF}(открыть планировщик событий в игре)")
    es_msg("{FFFF00}/esreset {FFFFFF}(сбросить кеш папки скриншотов)")
    
    sampRegisterChatCommand("es", function()
        start_detection_loop()

        capture_and_upload_screenshot(function(screen_url)
            if not screen_url then
                return
            end

            local lines = {
                string.format("--- Скан #%d | %s ---", #pending_reports + 1, get_readable_time()),
                "Screenshot: " .. screen_url
            }

            table.insert(pending_scans, {
                time = os.date("!%H:%M:%S", os.time() + 10800),
                url  = screen_url
            })

            table.insert(pending_reports, table.concat(lines, "\n"))
        end)
    end)

    sampRegisterChatCommand("ess", function(params)
        if #pending_reports == 0 then
            es_msg("Очередь пуста, нечего отправлять. Сначала используйте {FFFF00}/es", "FFAA00")
            return
        end

        params = params or ""

        local words = {}
        for w in params:gmatch("%S+") do
            table.insert(words, w)
        end

        if #words < 2 then
            es_msg("Использование: {FFFF00}/ess Название события Ник_Победителя {FFFFFF}(пример: {FFFF00}/ess русская рулетка Nehto_Otto{FFFFFF})", "FF4444")
            return
        end

        local winner_nick = words[#words]
        if not winner_nick:find("_") then
            es_msg("Ник победителя должен быть последним словом и содержать нижнее подчёркивание (например: Nehto_Otto)", "FF4444")
            return
        end

        table.remove(words, #words)
        local event_name = table.concat(words, " ")
        if event_name == "" then
            es_msg("Укажите название события перед ником победителя", "FF4444")
            return
        end

        stop_detection_loop()
        local players_snapshot = unique_players_order
        unique_players       = {}
        unique_players_order = {}

        local author_nick = get_local_nickname()

        es_msg(string.format("Отправка итогового отчёта (%d сканов, %d игроков) в базу... {FFFF00}Событие: %s | Победитель: %s | Автор: %s", #pending_reports, #players_snapshot, event_name, winner_nick, author_nick))

        local scans_snapshot = pending_scans
        pending_scans = {}

        local send_time_str = get_readable_time()
        local date_str = os.date("!%d.%m.%Y", os.time() + 10800)

        local event_name_utf8  = to_utf8(event_name)
        local winner_nick_utf8 = to_utf8(winner_nick)
        local author_nick_utf8 = to_utf8(author_nick)
        local players_utf8 = {}
        for _, name in ipairs(players_snapshot) do
            table.insert(players_utf8, to_utf8(name))
        end

        local payload = {
            date    = date_str,
            time    = send_time_str,
            event   = event_name_utf8,
            winner  = winner_nick_utf8,
            author  = author_nick_utf8,
            players = players_utf8,
            scans   = scans_snapshot
        }
        local payload_json = dkjson.encode(payload)

        send_report_to_d1(payload_json, function(success)
            if success then
                add_local_report(
                    date_str,
                    send_time_str,
                    scans_snapshot,
                    event_name_utf8,
                    winner_nick_utf8,
                    players_utf8,
                    author_nick_utf8
                )
                pending_reports = {}
            else
                for _, name in ipairs(players_snapshot) do
                    if not unique_players[name] then
                        unique_players[name] = true
                        table.insert(unique_players_order, name)
                    end
                end
                for _, scan in ipairs(scans_snapshot) do
                    table.insert(pending_scans, scan)
                end
                start_detection_loop()
            end
        end)
    end)

    sampRegisterChatCommand("eslast", function()
        fetch_last_report_from_d1(function(date_str, err)
            if not date_str then
                es_msg("Не удалось получить данные из базы: " .. tostring(err), "FF4444")
                return
            end

            local utc_tbl = parse_iso8601_utc(date_str)
            if not utc_tbl then
                es_msg("Не удалось разобрать дату последнего отчёта", "FF4444")
                return
            end

            local last_epoch = utc_table_to_local_epoch(utc_tbl)
            if not last_epoch then
                es_msg("Ошибка расчёта времени", "FF4444")
                return
            end

            local diff = os.time() - last_epoch
            if diff < 0 then diff = 0 end

            local minutes = math.floor(diff / 60)
            local seconds = diff % 60

            if minutes < 1 then
                es_msg(string.format("С последнего отчёта прошло: %d сек.", seconds))
            else
                es_msg(string.format("С последнего отчёта прошло: %d мин %d сек.", minutes, seconds))
            end
        end)
    end)

    sampRegisterChatCommand("esr", function()
        local hwid = get_hwid()
        if not hwid then
            es_msg("HWID ещё не определён. Попробуй через пару секунд.", "FFAA00")
            return
        end

        local nick = get_local_nickname()
        if not nick or nick == "Unknown" then
            es_msg("Не удалось определить твой ник. Попробуй ещё раз.", "FF4444")
            return
        end

        lua_thread.create(function()
            -- Вместо того, чтобы класть голый HWID прямо в URL (он бы
            -- фактически стал вечным ключом, если ссылка где-то
            -- засветится — в истории браузера, логах и т.п.), сначала
            -- просим воркер выдать одноразовый токен, который истекает
            -- максимум через минуту и гасится сразу после первого же
            -- использования сайтом.
            local gen_result = try_worker_urls(gen_token_worker, function(url)
                return { WORKER_TOKEN, hwid }
            end, 15000)

            if not gen_result or not gen_result.ok or not gen_result.token then
                local err = gen_result and gen_result.err or "timeout"
                if is_hwid_error(err) then
                    notify_hwid_denied()
                else
                    es_msg("Не удалось сгенерировать ссылку для входа: " .. tostring(err), "FF4444")
                end
                return
            end

            -- Используем & вместо ? для параметров внутри hash
            local url = "https://saportbati.github.io/eventCRM/author.html#/author/" .. nick .. "&token=" .. gen_result.token

            local channel = effil.channel()
            local thr = effil.thread(open_url_worker)(channel, url)
            active_threads[#active_threads+1] = thr

            local result = wait_for_channel(channel, 5000)
            if result and result.ok then
                es_msg("Открываю твой профиль в CRM ({FFFF00}" .. nick .. "{FFFFFF})...")
            else
                es_msg("Не удалось открыть браузер (" .. tostring(result and result.err or "timeout") .. ").", "FF4444")
                es_msg("Ссылка для ручного открытия (действует не дольше 1 минуты): {FFFF00}" .. url)
            end
        end)
    end)

    -- Секретная версия /esr: тот же одноразовый токен (гасится за 1
    -- использование и живёт не дольше минуты), но вместо открытия
    -- браузера ссылка просто копируется в буфер обмена — удобно, если
    -- нужно вставить её куда-то самому (другой браузер, устройство и т.п.),
    -- не запуская локальный.
    sampRegisterChatCommand("-esr", function()
        local hwid = get_hwid()
        if not hwid then
            es_msg("HWID ещё не определён. Попробуй через пару секунд.", "FFAA00")
            return
        end

        local nick = get_local_nickname()
        if not nick or nick == "Unknown" then
            es_msg("Не удалось определить твой ник. Попробуй ещё раз.", "FF4444")
            return
        end

        lua_thread.create(function()
            local gen_result = try_worker_urls(gen_token_worker, function(url)
                return { WORKER_TOKEN, hwid }
            end, 15000)

            if not gen_result or not gen_result.ok or not gen_result.token then
                local err = gen_result and gen_result.err or "timeout"
                if is_hwid_error(err) then
                    notify_hwid_denied()
                else
                    es_msg("Не удалось сгенерировать ссылку для входа: " .. tostring(err), "FF4444")
                end
                return
            end

            local url = "https://saportbati.github.io/eventCRM/author.html#/author/" .. nick .. "&token=" .. gen_result.token

            if copy_to_clipboard(url) then
                es_msg("Ссылка для входа скопирована в буфер обмена (действует не дольше 1 минуты, {FFFF00}" .. nick .. "{FFFFFF}).")
            else
                es_msg("Не удалось скопировать в буфер обмена. Ссылка (действует не дольше 1 минуты): {FFFF00}" .. url, "FF4444")
            end
        end)
    end)

    -- Открывает планировщик прямо в игре (то же окно, что раньше открывалось
    -- командой /espl — теперь она объединена с /esp).
    sampRegisterChatCommand("esp", function()
        if espl_open[0] then
            espl_open[0]    = false
            espl_modal_open = false
            return
        end

        local hwid = get_hwid()
        if not hwid then
            es_msg("HWID ещё не определён. Попробуй через пару секунд.", "FFAA00")
            return
        end

        resolve_espl_author()

        espl_dates         = espl_get_date_range()
        espl_selected_date = format_date_ymd(os.time() + MSK_OFFSET)
        espl_schedule       = {}
        espl_loading        = true
        espl_load_error      = ""
        espl_open[0]        = true

        espl_load_schedule(espl_selected_date, espl_apply_schedule_result)
    end)

    sampRegisterChatCommand("esreset", function()
        os.remove(SCREENS_CACHE_FILE)
        screens_root_folder = nil
        es_msg("Кеш папки со скриншотами сброшен. Открываю окно для повторной настройки...")
        resolve_screens_root(function(path)
            screens_root_folder = path
        end)
    end)

    wait(-1)
end