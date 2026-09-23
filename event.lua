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

local CUSTOM_FONT_URL   = "https://raw.githubusercontent.com/SaportBati/eventCRM/refs/heads/main/eventscrin.ttf"
local CUSTOM_FONT_FILE  = SCRIPT_DIR .. "eventscrin.ttf"
local CUSTOM_FONT_SIZE  = 16.0
local custom_font       = nil

local function is_custom_font_cached()
    local f = io.open(CUSTOM_FONT_FILE, "rb")
    if not f then return false end
    local size = f:seek("end") or 0
    f:close()

    return size >= 1024
end

local function ensure_custom_font_downloaded()
    if is_custom_font_cached() then return true end

    local ok_req, requests = pcall(require, "requests")
    if not ok_req or not requests then return false end

    local ok_get, resp = pcall(requests.get, CUSTOM_FONT_URL, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" },
        timeout = 10
    })
    if not ok_get or not resp or resp.status_code ~= 200 or not resp.text or #resp.text < 1024 then
        return false
    end

    local file = io.open(CUSTOM_FONT_FILE, "wb")
    if not file then return false end
    file:write(resp.text)
    file:close()
    return true
end

ensure_custom_font_downloaded()

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

    if is_custom_font_cached() then
        local ok_cf, font = pcall(function()
            return imgui_io.Fonts:AddFontFromFileTTF(CUSTOM_FONT_FILE, CUSTOM_FONT_SIZE, nil, ranges)
        end)
        if ok_cf and font then
            custom_font        = font
            imgui_io.FontDefault = font
        end
    end

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

local SCRIPT_VERSION      = "1.4"
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

DC = {
    linked        = false,
    checking      = false,
    polling       = false,
    raw_register  = sampRegisterChatCommand,
    lthreads      = {},
    ethreads      = {},
    inflight      = 0,
    MAX_INFLIGHT  = 3,
    esp_epoch     = 0,

    esp_thread    = nil,
}

function DC.spawn(fn, ...)
    local list = DC.lthreads
    if #list >= 32 then
        for i = #list, 1, -1 do
            local ok, dead = pcall(function() return list[i].dead end)
            if ok and dead == true then table.remove(list, i) end
        end
    end
    local thr = lua_thread.create(fn, ...)
    list[#list + 1] = thr
    return thr
end

function DC.reap()
    local list = DC.ethreads
    for i = #list, 1, -1 do
        local ok, status, err = pcall(function() return list[i]:status() end)
        if not ok then
            table.remove(list, i)
        elseif status == "completed" or status == "cancelled" or status == "failed" then
            if status == "failed" then
                print("[EventScan] effil-����� ���������� � �������: " .. tostring(err))
            end
            table.remove(list, i)
        end
    end
end

function DC.effil_start(fn, ...)
    DC.reap()
    local thr = effil.thread(fn)(...)
    DC.ethreads[#DC.ethreads + 1] = thr
    return thr
end

function DC.cancel_all()
    for _, thr in ipairs(DC.ethreads) do
        pcall(function() thr:cancel(0) end)
    end
end

function DC.avatar_worker(channel, url, path)
    local ok_r, requests = pcall(require, "requests")
    if not ok_r or not requests then
        channel:push({ ok = false, err = "no_requests" })
        return
    end
    local ok, resp = pcall(requests.get, url, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" },
        timeout = 25
    })
    if not ok then

        channel:push({ ok = false, err = "network_fail: " .. tostring(resp) })
        return
    end
    if not resp then
        channel:push({ ok = false, err = "network_fail: empty_response" })
        return
    end
    if resp.status_code ~= 200 or not resp.text or #resp.text < 100 then
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
        return
    end
    local body = resp.text
    local is_png  = body:sub(1, 4) == "\137PNG"
    local is_jpeg = body:sub(1, 2) == "\255\216"
    if not (is_png or is_jpeg) then
        channel:push({ ok = false, err = "not_png_or_jpeg" })
        return
    end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then
        channel:push({ ok = false, err = "write_fail" })
        return
    end
    f:write(body)
    f:close()
    os.remove(path)
    if not os.rename(tmp, path) then
        channel:push({ ok = false, err = "rename_fail" })
        return
    end
    channel:push({ ok = true })
end

function DC.esp_wait_worker(channel, worker_url, hwid, date, version)
    local ok_r, requests = pcall(require, "requests")
    if not ok_r or not requests then
        channel:push({ ok = false, err = "no_requests" })
        return
    end
    local ok_j, json = pcall(require, "dkjson")
    if not ok_j or not json then
        channel:push({ ok = false, err = "no_json" })
        return
    end

    local function url_encode(s)
        return (tostring(s):gsub("[^%w%-%._~]", function(c)
            return string.format("%%%02X", c:byte())
        end))
    end

    local qs = "date=" .. date .. "&version=" .. url_encode(version or "")
    local ok, resp = pcall(requests.get, worker_url .. "/esp/wait?" .. qs, {
        headers = {
            ["X-HWID"]     = hwid,
            ["User-Agent"] = "SAMP-EventScan/1.4"
        },
        timeout = 28
    })

    if not ok then
        channel:push({ ok = false, err = "network_fail: " .. tostring(resp) })
        return
    end
    if not resp then
        channel:push({ ok = false, err = "network_fail: empty_response" })
        return
    end
    if resp.status_code ~= 200 then
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
        return
    end

    local pok, data = pcall(json.decode, resp.text)
    if not pok or not data then
        channel:push({ ok = false, err = "json_parse_fail" })
        return
    end

    channel:push(data)
end

function DC.token_status_worker(channel, worker_url, token)
    local ok_r, requests = pcall(require, "requests")
    if not ok_r or not requests then
        channel:push({ ok = false, err = "no_requests" })
        return
    end
    local ok_j, json = pcall(require, "dkjson")
    if not ok_j or not json then
        channel:push({ ok = false, err = "no_json" })
        return
    end

    local ok, resp = pcall(requests.get, worker_url .. "/token-status?token=" .. token, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" },
        timeout = 10
    })

    if not ok then
        channel:push({ ok = false, err = "network_fail: " .. tostring(resp) })
        return
    end
    if not resp then
        channel:push({ ok = false, err = "network_fail: empty_response" })
        return
    end
    if resp.status_code ~= 200 then
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
        return
    end

    local pok, data = pcall(json.decode, resp.text)
    if not pok or not data or not data.ok then
        channel:push({ ok = false, err = "json_parse_fail" })
        return
    end

    channel:push({ ok = true, used = data.used, expired = data.expired })
end

function DC.is_image_file(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(4) or ""
    local size = f:seek("end") or 0
    f:close()
    if size < 100 then return false end
    return head:sub(1, 4) == "\137PNG" or head:sub(1, 2) == "\255\216"
end

function DC.dir_iter(path)
    local ok, it, obj = pcall(lfs.dir, path)
    if ok and it then return it, obj end
    return function() return nil end
end

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
    DC.spawn(function()
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

local DOW_LABELS_RU = { "��", "��", "��", "��", "��", "��", "��" }

local MSK_OFFSET = 10800

local function format_date_ymd(t)
    return os.date("!%Y-%m-%d", t)
end

local function espl_get_date_range()
    local days = {}
    local msk_now      = os.time() + MSK_OFFSET
    local msk_midnight = msk_now - (msk_now % 86400)
    for offset = -5, 3 do
        table.insert(days, msk_midnight + offset * 86400)
    end
    return days
end

local function espl_generate_time_slots()
    local slots = {}
    for hour = 0, 23 do
        for minute = 0, 59, 20 do
            table.insert(slots, string.format("%02d:%02d", hour, minute))
        end
    end
    return slots
end

local function espl_days_from_civil(y, m, d)
    y = y - ((m <= 2) and 1 or 0)
    local era = math.floor((y >= 0 and y or y - 399) / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + ((m > 2) and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

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
        if not DC.clip_cdef then
            DC.clip_cdef = true

            for _, decl in ipairs({
                "typedef int BOOL;",
                "typedef void* HANDLE;",
                "typedef void* HWND;",
                "typedef unsigned int UINT;",
                "BOOL OpenClipboard(HWND hWndNewOwner);",
                "BOOL CloseClipboard(void);",
                "BOOL EmptyClipboard(void);",
                "HANDLE SetClipboardData(UINT uFormat, HANDLE hMem);",
                "HANDLE GlobalAlloc(UINT uFlags, size_t dwBytes);",
                "void* GlobalLock(HANDLE hMem);",
                "BOOL GlobalUnlock(HANDLE hMem);",
            }) do
                pcall(ffi.cdef, decl)
            end
        end

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
    es_msg("���� HWID �� �������� � �������!", "FF4444")
    es_msg("�� ���������� � ����� ������ � ������� ��� ������������, ����� ���� ��������.", "FF4444")
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

    local b64
    local ok_m, mime = pcall(require, "mime")
    if ok_m and type(mime) == "table" and mime.b64 then
        local ok_b, res = pcall(mime.b64, binary_data)
        if ok_b and type(res) == "string" and #res > 0 then b64 = res end
    end
    if not b64 then b64 = encodeBase64(binary_data) end

    local payload = json.encode({ data = b64 })

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

local function gen_token_worker(channel, worker_url, token, hwid, purpose)
    local requests = require("requests")
    local json     = require("dkjson")

    local payload = json.encode({ purpose = purpose or "esr" })

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/gen-token", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Auth-Token"] = token,
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload
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
            channel:push({ ok = true, allowed = data.allowed, author = data.author,
                          discord_avatar = data.discord_avatar, discord_linked = data.discord_linked })
        else
            channel:push({ ok = false, err = "json_parse_fail" })
        end
    else
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
    end
end

local function my_stats_worker(channel, worker_url, hwid)
    local requests = require("requests")
    local json     = require("dkjson")

    local ok, resp = pcall(requests.get, worker_url .. "/my-stats", {
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
            channel:push({
                ok            = true,
                author        = data.author,
                reports_today = data.reports_today,
                reports_week  = data.reports_week,
                reports_all   = data.reports_all,
                balance       = data.balance
            })
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

local function wait_for_channel(channel, timeout_ms, thr)
    local waited = 0
    local POLL = 30
    while waited < timeout_ms do
        local data = channel:pop(0)
        if data ~= nil then
            return data
        end

        if thr then
            local ok, status, err = pcall(function() return thr:status() end)
            if ok and (status == "failed" or status == "completed" or status == "cancelled") then
                local last = channel:pop(0)
                if last ~= nil then return last end
                if status == "failed" then
                    return { ok = false, err = "worker_failed: " .. tostring(err) }
                end
                return { ok = false, err = "worker_no_result" }
            end
        end

        wait(POLL)
        waited = waited + POLL
    end
    return nil
end

local PRIMARY_WORKER_TIMEOUT_MS = 6000

local function is_network_failure(result)
    if result == nil then return true end
    if result.ok then return false end
    local err = tostring(result.err or "")
    return err == "" or err == "network_fail" or err:find("^worker_") ~= nil
        or err:find("^thread_start_fail") ~= nil or err:find("^http_5") ~= nil
        or err == "json_parse_fail"
end

local function try_worker_urls(worker_fn, build_args, timeout_ms)
    local function attempt(url, attempt_timeout_ms)

        local guard = 0
        while DC.inflight >= DC.MAX_INFLIGHT and guard < 600 do
            wait(50)
            guard = guard + 1
        end
        DC.inflight = DC.inflight + 1

        local result
        local ok_args, args = pcall(build_args, url)
        if not ok_args or type(args) ~= "table" then
            result = { ok = false, err = "thread_start_fail: bad_args" }
        else
            local channel = effil.channel()
            local ok_start, thr = pcall(function()
                return DC.effil_start(worker_fn, channel, url, unpack(args))
            end)
            if ok_start then
                result = wait_for_channel(channel, attempt_timeout_ms, thr)
            else
                result = { ok = false, err = "thread_start_fail: " .. tostring(thr) }
            end
        end

        DC.inflight = math.max(DC.inflight - 1, 0)
        return result
    end

    local has_fallback    = active_worker_url ~= WORKER_URL_FALLBACK
    local primary_timeout = has_fallback and math.min(PRIMARY_WORKER_TIMEOUT_MS, timeout_ms) or timeout_ms

    local result = attempt(active_worker_url, primary_timeout)
    if result and result.ok then
        return result
    end

    if has_fallback and is_network_failure(result) then
        print(string.format("[EventScan] �������� Worker (%s) �� �������: %s. ������ ��������� (%s)...",
            active_worker_url, tostring(result and result.err or "timeout"), WORKER_URL_FALLBACK))

        local fallback_result = attempt(WORKER_URL_FALLBACK, timeout_ms)
        if fallback_result and fallback_result.ok then
            active_worker_url = WORKER_URL_FALLBACK
            print(string.format("[EventScan] ��������� Worker (%s) ��������. ������������ �� ���� �� ����� ������.", WORKER_URL_FALLBACK))
            return fallback_result
        end

        print(string.format("[EventScan] ��������� Worker (%s) ���� �� �������: %s.",
            WORKER_URL_FALLBACK, tostring(fallback_result and fallback_result.err or "timeout")))

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
    local thr = DC.effil_start(generate_hwid_worker, channel)

    DC.spawn(function()
        local result = wait_for_channel(channel, 20000, thr)

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
local screens_path_status = '��� ���������, ���������...'
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

local espl_open          = imgui_new.bool(false)
local espl_dates         = nil
local espl_selected_date = nil
local espl_schedule      = {}
local espl_loading       = false
local espl_load_error    = ""

local espl_modal_open        = false
local espl_modal_mode        = nil
local espl_modal_time         = nil
local espl_modal_title_buf   = imgui_new.char[128](0)
local espl_modal_view_author = ""
local espl_modal_view_title  = ""
local espl_modal_busy        = false
local espl_modal_error       = ""

local espl_local_author     = nil
local espl_author_resolved  = false
local espl_author_resolving = false

local espl_panel = {
    loading    = false,
    loaded     = false,
    error      = "",
    author     = nil,
    today      = 0,
    week       = 0,
    all        = 0,
    balance    = 0,
    avatar_file = SCRIPT_DIR .. "espl_avatar.png",
    avatar_url   = nil,
    avatar_tex   = nil,
    avatar_ready = false,
    refreshing   = false,
}

local espl_top3 = {}

local function espl_format_balance(val)
    local s = tostring(math.abs(val))
    local result = ""
    local len = #s
    for i = 1, len do
        result = result .. s:sub(i, i)
        local remaining = len - i
        if remaining > 0 and remaining % 3 == 0 then
            result = result .. "."
        end
    end
    if val < 0 then result = "-" .. result end
    return "$" .. result
end

local function espl_load_my_stats()
    if espl_panel.loading then return end
    local hwid = get_hwid()
    if not hwid then return end

    espl_panel.loading = true
    espl_panel.error   = ""
    DC.spawn(function()
        local result = try_worker_urls(my_stats_worker, function(url)
            return { hwid }
        end, 15000)

        if result and result.ok then
            espl_panel.author  = result.author
            espl_panel.today   = result.reports_today or 0
            espl_panel.week    = result.reports_week  or 0
            espl_panel.all     = result.reports_all   or 0
            espl_panel.balance = result.balance        or 0
            espl_panel.loaded  = true
            espl_panel.error   = ""
        else
            espl_panel.error = result and result.err or "unknown"
        end
        espl_panel.loading = false
    end)
end

local function resolve_espl_author(callback)

    local avatar_retry = espl_panel.avatar_url ~= nil and not espl_panel.avatar_tex
        and not espl_panel.avatar_ready and (espl_panel.avatar_tries or 0) < 3

    if espl_author_resolved and not avatar_retry then
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
    DC.spawn(function()
        local result = try_worker_urls(check_hwid_worker, function(url)
            return { hwid }
        end, 15000)

        if result and result.ok and result.author then
            espl_local_author = result.author
        end

        if result and result.ok and result.discord_avatar and result.discord_avatar ~= "" then
            espl_panel.avatar_url = result.discord_avatar
            if not espl_panel.avatar_ready and not espl_panel.avatar_tex
                and (espl_panel.avatar_tries or 0) < 3 then
                espl_panel.avatar_tries = (espl_panel.avatar_tries or 0) + 1

                local hash = espl_panel.avatar_url:match("/avatars/%d+/([%w_]+)%.")
                if hash then
                    espl_panel.avatar_file = SCRIPT_DIR .. "espl_avatar_" .. hash .. ".png"
                end

                if DC.is_image_file(espl_panel.avatar_file) then

                    espl_panel.avatar_ready = true
                else
                    os.remove(espl_panel.avatar_file)

                    local avatar_fetch_url = active_worker_url:gsub("/+$", "")
                        .. "/avatar-proxy?hwid=" .. DC.url_encode(hwid)
                    local ch = effil.channel()
                    local ok_s, thr = pcall(DC.effil_start, DC.avatar_worker,
                        ch, avatar_fetch_url, espl_panel.avatar_file)
                    if ok_s then
                        local r = wait_for_channel(ch, 25000, thr)
                        if r and r.ok and DC.is_image_file(espl_panel.avatar_file) then
                            espl_panel.avatar_ready = true
                        else
                            print("[EventScan] �� ������� ������� ��������: " .. tostring(r and r.err or "timeout"))
                        end
                    else
                        print("[EventScan] �� ������� ��������� �������� ��������: " .. tostring(thr))
                    end
                end
            end
        end

        if result and result.ok then
            espl_author_resolved = true
        end
        espl_author_resolving = false

        if callback then callback(espl_local_author) end
    end)
end

local ESPL_AVATAR_REFRESH_TIMEOUT_MS = 120000
local ESPL_AVATAR_REFRESH_POLL_MS    = 3000

local function espl_refresh_avatar()
    if espl_panel.refreshing then return end

    local hwid = get_hwid()
    if not hwid then
        es_msg("HWID ��� �� ��������. �������� ����� ���� ������.", "FFAA00")
        return
    end

    espl_panel.refreshing = true

    DC.spawn(function()
        local gen_result = try_worker_urls(gen_token_worker, function(url)
            return { WORKER_TOKEN, hwid, "discord" }
        end, 15000)

        if not gen_result or not gen_result.ok or not gen_result.token then
            local err = gen_result and gen_result.err or "timeout"
            if is_hwid_error(err) then
                notify_hwid_denied()
            else
                es_msg("�� ������� ����������� ������ �����������: " .. tostring(err), "FF4444")
            end
            espl_panel.refreshing = false
            return
        end

        local token = gen_result.token
        local base  = WORKER_URL_PRIMARY:gsub("/+$", "")
        local url   = base .. "/discord-auth?token=" .. DC.url_encode(token)

        local channel = effil.channel()
        local thr = DC.effil_start(open_url_worker, channel, url)
        local open_result = wait_for_channel(channel, 5000, thr)

        if not (open_result and open_result.ok) then
            copy_to_clipboard(url)
            es_msg("�� ������� ������� �������. ������ ����������� � ����� ������ � ������ � � �������.", "FF4444")
        else
            es_msg("�������� �������� ����������� Discord � ��������...")
        end

        local waited    = 0
        local completed = false

        while waited < ESPL_AVATAR_REFRESH_TIMEOUT_MS do
            wait(ESPL_AVATAR_REFRESH_POLL_MS)
            waited = waited + ESPL_AVATAR_REFRESH_POLL_MS

            local status_result = try_worker_urls(DC.token_status_worker, function(u)
                return { token }
            end, 10000)

            if status_result and status_result.ok then
                if status_result.used then
                    completed = true
                    break
                end
                if status_result.expired then
                    break
                end
            end
        end

        if not completed then
            espl_panel.refreshing = false
            es_msg("�� ������� ����������� ����������� (������ �� ���� ������� ��� ������� ����� ��������). �������� ��� ���.", "FFAA00")
            return
        end

        local r = try_worker_urls(check_hwid_worker, function(u)
            return { hwid }
        end, 15000)

        if r and r.ok then
            if r.author then
                espl_local_author = r.author
            end

            if r.discord_avatar and r.discord_avatar ~= "" then
                espl_panel.avatar_url   = r.discord_avatar
                espl_panel.avatar_tex   = nil
                espl_panel.avatar_ready = false
                espl_panel.avatar_tries = 0

                local hash = espl_panel.avatar_url:match("/avatars/%d+/([%w_]+)%.")
                if hash then
                    espl_panel.avatar_file = SCRIPT_DIR .. "espl_avatar_" .. hash .. ".png"
                end

                os.remove(espl_panel.avatar_file)

                local avatar_fetch_url = active_worker_url:gsub("/+$", "")
                    .. "/avatar-proxy?hwid=" .. DC.url_encode(hwid)
                local ch = effil.channel()
                local ok_s, thr2 = pcall(DC.effil_start, DC.avatar_worker,
                    ch, avatar_fetch_url, espl_panel.avatar_file)
                if ok_s then
                    local dl_r = wait_for_channel(ch, 25000, thr2)
                    if dl_r and dl_r.ok and DC.is_image_file(espl_panel.avatar_file) then
                        espl_panel.avatar_ready = true
                    else
                        print("[EventScan] �� ������� ������� ��������: " .. tostring(dl_r and dl_r.err or "timeout"))
                    end
                else
                    print("[EventScan] �� ������� ��������� �������� ��������: " .. tostring(thr2))
                end
            end

            es_msg("������ Discord ���������!")
        else
            es_msg("����������� ������, �� �� ������� �������� ���������� ������: " .. tostring(r and r.err or "timeout"), "FFAA00")
        end

        espl_panel.refreshing = false
    end)
end

local function espl_load_schedule(date_str, callback)
    DC.spawn(function()
        local result = try_worker_urls(plan_fetch_worker, function(url)
            return { date_str }
        end, 15000)

        if date_str ~= espl_selected_date then return end
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
        espl_load_error = u8("�� ������� ��������� ����������: ") .. tostring(result and result.err or "timeout")
    end
end

function DC.esp_stop_polling()
    DC.esp_epoch = DC.esp_epoch + 1
    if DC.esp_thread then
        pcall(function() DC.esp_thread:cancel(0) end)
        DC.esp_thread = nil
    end
end

function DC.esp_start_polling(date_str)
    DC.esp_stop_polling()
    local my_epoch = DC.esp_epoch
    local version   = ""

    DC.spawn(function()
        while espl_open[0] and my_epoch == DC.esp_epoch and date_str == espl_selected_date do
            local hwid = get_hwid()
            if not hwid then
                wait(1000)
            else
                local channel = effil.channel()

                local ok_s, thr = pcall(DC.effil_start, DC.esp_wait_worker,
                    channel, active_worker_url, hwid, date_str, version)

                local result
                if ok_s then

                    if my_epoch == DC.esp_epoch then
                        DC.esp_thread = thr
                    end
                    result = wait_for_channel(channel, 32000, thr)
                    if DC.esp_thread == thr then
                        DC.esp_thread = nil
                    end
                else
                    result = { ok = false, err = "thread_start_fail: " .. tostring(thr) }
                end

                if not espl_open[0] or my_epoch ~= DC.esp_epoch or date_str ~= espl_selected_date then
                    return
                end

                if result and result.ok then
                    version = result.version or version
                    if result.changed then
                        espl_loading    = false
                        espl_load_error = ""

                        local sched = {}
                        for _, s in ipairs(result.slots or {}) do
                            sched[s.time] = { author = s.author, title = s.title }
                        end
                        espl_schedule = sched

                        if result.stats then
                            espl_panel.author  = result.stats.author
                            espl_panel.today   = result.stats.reports_today or 0
                            espl_panel.week    = result.stats.reports_week or 0
                            espl_panel.all      = result.stats.reports_all or 0
                            espl_panel.balance  = result.stats.balance or 0
                            espl_panel.loaded   = true
                            espl_panel.error    = ""
                        end

                        if result.top3 then
                            espl_top3 = result.top3
                        end
                    end
                else

                    if espl_loading then
                        espl_load_error = u8("�� ������� ��������� ����������: ")
                            .. tostring(result and result.err or "timeout")
                    end
                    wait(1000)
                end
            end
        end
    end)
end

local function espl_select_date(ds)
    if ds == espl_selected_date then return end
    espl_selected_date = ds
    espl_schedule       = {}
    espl_loading        = true
    espl_load_error      = ""
    DC.esp_start_polling(ds)
end

local ESPL_AMBER = "d4a24e"
local ESPL_ELLIPSIS = u8("�")

local ESPL_MEDAL_COLORS = { "FFD700", "C0C0C0", "CD7F32" }

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

local function espl_author_colors(author)
    local key = (author and author ~= "") and author or "�"
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

local function espl_short_nick(author)
    if not author or author == "" then return author end
    local nick = author:match("^([^_]+)")
    return nick or author
end

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
            local dow_text  = is_today and "�������" or DOW_LABELS_RU[tbl.wday]
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
            status_text  = u8("�������� ����������...")
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

    local main_win_pos  = imgui.GetWindowPos()
    local main_win_size = imgui.GetWindowSize()

    imgui.End()

    local SIDE_GAP = 8
    imgui.SetNextWindowPos(
        imgui.ImVec2(main_win_pos.x + main_win_size.x + SIDE_GAP, main_win_pos.y),
        imgui.Cond.Always
    )

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 6))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 14))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.055, 0.075, 0.055, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))

    imgui.Begin('##espl_side_panel', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoMove)

    local SIDE_W = 180

    local avatar_size = 64
    local avatar_rounding = 10
    local content_w = imgui.GetContentRegionAvail().x
    local avatar_offset_x = (content_w - avatar_size) / 2
    if avatar_offset_x > 0 then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + avatar_offset_x)
    end
    local avatar_pos = imgui.GetCursorScreenPos()
    imgui.Dummy(imgui.ImVec2(avatar_size, avatar_size))
    local draw_list = imgui.GetWindowDrawList()
    local avatar_p2 = imgui.ImVec2(avatar_pos.x + avatar_size, avatar_pos.y + avatar_size)

    if espl_panel.avatar_ready and not espl_panel.avatar_tex then

        local ok_tex, tex = pcall(imgui.CreateTextureFromFile, espl_panel.avatar_file)
        if ok_tex and tex then
            espl_panel.avatar_tex = tex
        end
        espl_panel.avatar_ready = false
        if not espl_panel.avatar_tex then
            os.remove(espl_panel.avatar_file)
            print("[EventScan] �� ������� ������� �������� ��������, ���� �����.")
        end
    end

    if espl_panel.avatar_tex then

        draw_list:AddImageRounded(
            espl_panel.avatar_tex,
            avatar_pos, avatar_p2,
            imgui.ImVec2(0, 0), imgui.ImVec2(1, 1),
            0xFFFFFFFF,
            avatar_rounding
        )

        draw_list:AddRect(avatar_pos, avatar_p2,
            imgui.ColorConvertFloat4ToU32(hexcol(GREEN_MID, 0.6)),
            avatar_rounding, 15, 1.5
        )
    else

        draw_list:AddRect(avatar_pos, avatar_p2,
            imgui.ColorConvertFloat4ToU32(hexcol(GREEN_MID, 0.6)),
            avatar_rounding, 15, 1.5
        )
        local icon_text = "?"
        local icon_w = imgui.CalcTextSize(icon_text).x
        local icon_h = imgui.GetTextLineHeight()
        draw_list:AddText(
            imgui.ImVec2(avatar_pos.x + (avatar_size - icon_w) / 2, avatar_pos.y + (avatar_size - icon_h) / 2),
            imgui.ColorConvertFloat4ToU32(hexcol(GREEN_MID, 0.4)), icon_text
        )
    end

    imgui.Spacing()

    if espl_panel.loading then
        center_text(u8("��������..."), hexcol(GREEN_BRIGHT, 0.7))
    elseif espl_panel.error ~= "" then
        center_text(u8("������"), imgui.ImVec4(1, 0.35, 0.35, 1))
    else

        local nick_display = espl_panel.author or espl_local_author or "�"
        center_text(nick_display, hexcol(GREEN_BRIGHT))

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
        imgui.Separator()
        imgui.PopStyleColor(1)
        imgui.Spacing()

        local bal_str = espl_format_balance(espl_panel.balance)
        local bal_color = espl_panel.balance >= 0
            and hexcol(GREEN_BRIGHT)
            or imgui.ImVec4(1, 0.35, 0.35, 1)
        center_text(bal_str, bal_color)

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
        imgui.Separator()
        imgui.PopStyleColor(1)
        imgui.Spacing()

        local label_color = imgui.ImVec4(0.65, 0.75, 0.65, 1)
        local value_color = imgui.ImVec4(1, 1, 1, 1)

        imgui.TextColored(label_color, u8("�������:"))
        imgui.SameLine(SIDE_W - imgui.CalcTextSize(tostring(espl_panel.today)).x)
        imgui.TextColored(value_color, tostring(espl_panel.today))

        imgui.TextColored(label_color, u8("�� ������:"))
        imgui.SameLine(SIDE_W - imgui.CalcTextSize(tostring(espl_panel.week)).x)
        imgui.TextColored(value_color, tostring(espl_panel.week))

        imgui.TextColored(label_color, u8("�����:"))
        imgui.SameLine(SIDE_W - imgui.CalcTextSize(tostring(espl_panel.all)).x)
        imgui.TextColored(value_color, tostring(espl_panel.all))

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
        imgui.Separator()
        imgui.PopStyleColor(1)
        imgui.Spacing()

        if espl_panel.refreshing then
            center_text(u8("����������..."), hexcol(GREEN_BRIGHT, 0.7))
        else
            if imgui.Button(u8("�������� ��������"), imgui.ImVec2(SIDE_W, 26)) then
                espl_refresh_avatar()
            end
        end
    end

    local side_win_pos  = imgui.GetWindowPos()
    local side_win_size = imgui.GetWindowSize()

    imgui.End()

    local top3_win_x      = side_win_pos.x
    local top3_win_y      = side_win_pos.y + side_win_size.y + SIDE_GAP
    local top3_win_w      = side_win_size.x
    local top3_win_h      = math.max(
        (main_win_pos.y + main_win_size.y) - top3_win_y,
        60
    )

    imgui.SetNextWindowPos(imgui.ImVec2(top3_win_x, top3_win_y), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(top3_win_w, top3_win_h), imgui.Cond.Always)

    imgui.Begin('##espl_top3_panel', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
        imgui.WindowFlags.NoScrollWithMouse)

    local top3_content_w = imgui.GetContentRegionAvail().x

    center_text(u8("��� �� ������"), hexcol(GREEN_BRIGHT))
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
    imgui.Separator()
    imgui.PopStyleColor(1)
    imgui.Spacing()

    if #espl_top3 == 0 then
        center_text(u8("���� ��� �������"), imgui.ImVec4(0.6, 0.6, 0.6, 1))
        imgui.Dummy(imgui.ImVec2(top3_content_w, 4))
    else
        local n           = #espl_top3
        local BAR_MAX_W   = top3_content_w
        local avail_h     = imgui.GetContentRegionAvail().y
        local row_h       = avail_h / n
        local text_h      = imgui.GetTextLineHeight()
        local row_start_y = imgui.GetCursorPosY()

        local max_count = (espl_top3[1] and espl_top3[1].count) or 1
        if not max_count or max_count <= 0 then max_count = 1 end

        for i, entry in ipairs(espl_top3) do
            local row_top = row_start_y + (i - 1) * row_h
            local gap     = math.min(4, row_h * 0.12)
            local bar_h   = math.max(row_h - text_h - gap, 4)

            local medal_hex = ESPL_MEDAL_COLORS[i] or GREEN_MID
            local count_val = entry.count or 0
            local frac      = math.max(count_val / max_count, 0.04)
            local bar_w     = math.max(BAR_MAX_W * frac, 4)

            local nick       = espl_short_nick(entry.author) or entry.author or "�"
            local count_str  = tostring(count_val)
            local label      = i .. ". " .. nick
            local label_max_w = BAR_MAX_W - imgui.CalcTextSize(count_str).x - 8

            imgui.SetCursorPosY(row_top)
            imgui.TextColored(hexcol(medal_hex), espl_truncate_to_width(label, label_max_w))
            imgui.SameLine(BAR_MAX_W - imgui.CalcTextSize(count_str).x)
            imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), count_str)

            imgui.SetCursorPosY(row_top + text_h + gap)
            local bar_pos   = imgui.GetCursorScreenPos()
            local draw_list = imgui.GetWindowDrawList()
            draw_list:AddRectFilled(
                bar_pos,
                imgui.ImVec2(bar_pos.x + BAR_MAX_W, bar_pos.y + bar_h),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.08)), 4
            )
            draw_list:AddRectFilled(
                bar_pos,
                imgui.ImVec2(bar_pos.x + bar_w, bar_pos.y + bar_h),
                imgui.ColorConvertFloat4ToU32(hexcol(medal_hex, 0.85)), 4
            )
        end
        imgui.SetCursorPosY(row_start_y + avail_h)
    end

    imgui.End()

    imgui.PopStyleColor(3)
    imgui.PopStyleVar(4)

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

    imgui.SetNextWindowFocus()

    imgui.Begin('##espl_modal_window', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoSavedSettings +
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize)

    local MODAL_CONTENT_W = 300

    center_text(u8(tostring(espl_selected_date) .. " � " .. tostring(espl_modal_time)), hexcol(GREEN_BRIGHT))
    imgui.Spacing()

    if espl_modal_mode == "foreign" then
        imgui.Text(u8("�����:"))
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
        imgui.Text(u8("��������:"))
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
        center_text(u8("��������..."), hexcol(GREEN_BRIGHT))
    elseif espl_modal_mode == "foreign" then
        if imgui.Button(u8("�������"), imgui.ImVec2(MODAL_CONTENT_W, 32)) then
            espl_modal_open = false
        end
    else
        local avail      = MODAL_CONTENT_W
        local gap        = 8
        local has_delete = espl_modal_mode == "own"
        local btn_count  = has_delete and 3 or 2
        local btn_w      = (avail - gap * (btn_count - 1)) / btn_count

        if imgui.Button(u8("���������"), imgui.ImVec2(btn_w, 32)) then
            local title = ffi.string(espl_modal_title_buf)
            title = title:gsub('^%s+', ''):gsub('%s+$', '')

            if title == "" then
                espl_modal_error = u8("������� �������� �����������")
            else
                local hwid = get_hwid()
                if not hwid then
                    espl_modal_error = u8("HWID ��� �� ��������")
                else
                    espl_modal_busy = true
                    local time = espl_modal_time
                    local date = espl_selected_date

                    DC.spawn(function()
                        local result = try_worker_urls(plan_save_worker, function(url)
                            return { hwid, date, time, title }
                        end, 15000)
                        espl_modal_busy = false

                        if result and result.ok then
                            espl_schedule[time] = { author = result.author, title = result.title }
                            espl_modal_open = false
                        else
                            local err = result and result.err or "timeout"
                            espl_modal_error = u8("������ ����������: ") .. tostring(err)
                        end
                    end)
                end
            end
        end

        imgui.SameLine(0, gap)

        if has_delete then
            if imgui.Button(u8("�������"), imgui.ImVec2(btn_w, 32)) then
                local hwid = get_hwid()
                if not hwid then
                    espl_modal_error = u8("HWID ��� �� ��������")
                else
                    espl_modal_busy = true
                    local time = espl_modal_time
                    local date = espl_selected_date

                    DC.spawn(function()
                        local result = try_worker_urls(plan_delete_worker, function(url)
                            return { hwid, date, time }
                        end, 15000)
                        espl_modal_busy = false

                        if result and result.ok then
                            espl_schedule[time] = nil
                            espl_modal_open = false
                        else
                            local err = result and result.err or "timeout"
                            espl_modal_error = u8("������ ��������: ") .. tostring(err)
                        end
                    end)
                end
            end
            imgui.SameLine(0, gap)
        end

        if imgui.Button(u8("������"), imgui.ImVec2(btn_w, 32)) then
            espl_modal_open = false
        end
    end

    imgui.End()

    imgui.PopStyleColor(5)
    imgui.PopStyleVar(5)
end)

local toast_visible = imgui_new.bool(false)
local toast_state = {
    text       = "",
    color      = nil,
    anim_time  = 0,
    start_tick = 0,
    closing    = false
}

local TOAST_ANIM_DURATION = 0.3
local TOAST_CLOSE_DURATION = 0.25

local function show_toast(text, color_hex)

    if screens_path_open[0] then
        return
    end

    toast_state.text    = text
    toast_state.color   = color_hex and hexcol(color_hex) or hexcol(GREEN_BRIGHT)
    toast_state.closing = false

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

local TOAST_PAD = 12

imgui.OnFrame(function() return toast_visible[0] and not screens_path_open[0] end, function()

    local elapsed = os.clock() - toast_state.start_tick

    local anim_progress
    if toast_state.closing then

        toast_state.anim_time = math.min(elapsed / TOAST_CLOSE_DURATION, 1.0)

        if toast_state.anim_time >= 1.0 then
            toast_visible[0] = false
            toast_state.closing = false
            return
        end

        anim_progress = 1.0 - toast_state.anim_time
    else

        toast_state.anim_time = math.min(elapsed / TOAST_ANIM_DURATION, 1.0)
        anim_progress = toast_state.anim_time
    end

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

    local win_w, win_h = 160, 40
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
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.0, 0.0, 0.0, 0.0))
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

    local draw_list = imgui.GetWindowDrawList()
    local win_pos = imgui.GetWindowPos()
    local win_size = imgui.GetWindowSize()
    local gap = 3
    local inner_rounding = 15

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

    local text = toast_state.text
    local text_color = toast_state.color
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
end).HideCursor = true

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
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.0, 0.0, 0.0, 0.0))
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

    local draw_list = imgui.GetWindowDrawList()
    local win_pos = imgui.GetWindowPos()
    local win_size = imgui.GetWindowSize()
    local gap = 3
    local inner_rounding = 15

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
end).HideCursor = true

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
    imgui.Begin(u8('��������� EventScan'), nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoSavedSettings)
    center_text(u8('�� ������� ����� �� ����������� (arizona\\screens).'))
    center_text(u8('�������� ����, ������� "�����..." ��� "����" ��� ����������.'))
    center_text(u8('���� � �����:'), hexcol(GREEN_BRIGHT))
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

        if imgui.Button(u8('������'), imgui.ImVec2(btn_w, 34)) then
            local path = ffi.string(screens_path_buf)
            path = path:gsub('^%s+', ''):gsub('%s+$', ''):gsub('"', '')

            path = utf8_to_ansi(path)
            if path == "" then
                screens_path_error = "������� ���� � �����"
            elseif not is_dir(path) then
                screens_path_error = "����� ����� �� ����������"
            else
                screens_path_error = ""
                screens_path_result = { mode = "manual", path = path }
            end
        end
        imgui.SameLine(0, gap)
        if imgui.Button(u8('�����...'), imgui.ImVec2(btn_w, 34)) then
            screens_path_error = ""
            screens_path_result = { mode = "browse" }
        end
        imgui.SameLine(0, gap)
        if imgui.Button(u8('����'), imgui.ImVec2(btn_w, 34)) then
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

    DC.spawn(function()
        while true do
            while screens_path_result == nil do
                wait(50)
            end

            local action = screens_path_result
            screens_path_result = nil

            if action.mode == "manual" then

                screens_path_error  = ""
                screens_path_busy   = true
                screens_path_status = '�������� ����� � ��� �������� �������� (F8)...'

                local ok = verify_screens_folder(action.path)
                screens_path_busy = false

                if ok then
                    screens_path_open[0] = false
                    save_cached_screens_root(action.path)
                    es_msg("����� ������������ � �������� �������� ������!")
                    callback(action.path)
                    return
                else
                    screens_path_error = "�������� �������� �� �������� � ���� ����� �� ��������� �����. ��������� ���� � ���������� �����."
                end
            elseif action.mode == "browse" then

                screens_path_error   = ""
                screens_path_busy    = true
                screens_path_status  = '������ ��������� ������ ������ �����...'

                local browse_channel = effil.channel()
                local browse_thr = DC.effil_start(browse_folder_worker,
                    browse_channel, u8('�������� ����� arizona\\screens')
                )

                local browse_result = wait_for_channel(browse_channel, 120000)

                if not browse_result or not browse_result.ok then
                    screens_path_busy = false
                    if browse_result and browse_result.err == "cancelled" then
                    else
                        screens_path_error = "�� ������� ������� ������ ������ �����. ������� ���� �������."
                    end
                else
                    local chosen_path = browse_result.path
                    screens_path_buf[0] = 0
                    ffi.copy(screens_path_buf, chosen_path, math.min(#chosen_path, ffi.sizeof(screens_path_buf) - 1))

                    if not is_dir(chosen_path) then
                        screens_path_busy = false
                        screens_path_error = "��������� ����� ����������."
                    else
                        screens_path_status = '�������� ����� � ��� �������� �������� (F8)...'

                        local ok = verify_screens_folder(chosen_path)
                        screens_path_busy = false

                        if ok then
                            screens_path_open[0] = false
                            save_cached_screens_root(chosen_path)
                            es_msg("����� ������������ � �������� �������� ������!")
                            callback(chosen_path)
                            return
                        else
                            screens_path_error = "�������� �������� �� �������� � ���� ����� �� ��������� �����. ��������� ���� � ���������� �����."
                        end
                    end
                end
            else
                screens_path_busy   = true
                screens_path_status = '��� ���������, ���������...'

                local found = find_screens_folder_everywhere()

                if not found then
                    screens_path_status = '�� ����� ����� �������� � ��� ��������� � ���������� ��������� � ���� (F8)...'
                    found = find_screens_folder_via_chatlog()
                end

                if found then

                    screens_path_status = '�����! �������� ����� � ��� �������� �������� (F8)...'
                    local ok = verify_screens_folder(found)
                    screens_path_busy = false

                    if ok then
                        screens_path_open[0] = false
                        save_cached_screens_root(found)
                        es_msg("����� � ���������� �������� ����������! �������, ����� �� ������ ������!")
                        callback(found)
                        return
                    else
                        screens_path_error = "����� ������� �����������, �� �������� �������� � ��� �� ��������. ������� ���� �������."
                    end
                else
                    screens_path_busy = false
                    screens_path_error = "�� ������� ������������� (������� ����� ����� ���-���). ������� ���� �������."
                end
            end
        end
    end)
end

find_latest_screenshot_in = function(root_folder)
    local latest_subfolder = nil
    local max_folder_time = 0
    for file_name in DC.dir_iter(root_folder) do
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
    for file_name in DC.dir_iter(latest_subfolder) do
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
        show_toast(u8("����� �� ���������"), "FFAA00")
        return callback(nil)
    end
    if not get_hwid() then
        show_toast(u8("Hwid"), "FFAA00")
        return callback(nil)
    end
    local root_folder = screens_root_folder

    DC.spawn(function()
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
            show_toast(u8("������!"), "FF4444")
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
            show_toast(u8("������!"), "FF4444")
            wait(2000)
            hide_toast()
            return callback(nil)
        end
        local binary_data = file:read("*a")
        file:close()

        show_toast(u8("��������..."), GREEN_BRIGHT)

        local hwid_value = get_hwid()
        local result = try_worker_urls(screenshot_upload_worker, function(url)
            return { WORKER_TOKEN, binary_data, hwid_value }
        end, 20000)
        if result and result.ok then
            show_toast(u8("������!"), GREEN_BRIGHT)
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
                show_toast(u8("������!"), "FF4444")
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
        es_msg("HWID ��� ������������ � ���� � �������� ��������� ����� ����� ���� ������.", "FFAA00")
        if on_done then on_done(false) end
        return
    end

    show_ess_toast(u8("��������..."), GREEN_BRIGHT)

    DC.spawn(function()
        local result = try_worker_urls(d1_report_worker, function(url)
            return { WORKER_TOKEN, payload_json, hwid }
        end, 20000)
        if result and result.ok then
            show_ess_toast(u8("������!"), GREEN_BRIGHT)
            wait(2000)
            hide_ess_toast()
            es_msg("����� ������� �������� � ���� ������!")
            if on_done then on_done(true) end
        else
            local err = result and result.err or "timeout"
            if is_hwid_error(err) then
                show_ess_toast(u8("������ HWID!"), "FF4444")
                wait(2000)
                hide_ess_toast()
                notify_hwid_denied()
            else
                show_ess_toast(u8("������!"), "FF4444")
                wait(2000)
                hide_ess_toast()
                es_msg("������ ���������� ������: " .. tostring(err), "FF4444")
            end
            if on_done then on_done(false) end
        end
    end)
end

local function fetch_last_report_from_d1(on_done)
    DC.spawn(function()
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

    es_msg("�������� ����������...")

    DC.spawn(function()
        local channel = effil.channel()
        local thr = DC.effil_start(update_download_worker, channel, UPDATE_DOWNLOAD_URL)

        local result = wait_for_channel(channel, 30000, thr)
        update_in_progress = false

        if not result or not result.ok or not result.data then
            es_msg("�� ������� ������� ����������: " .. tostring(result and result.err or "timeout"), "FF4444")
            return
        end

        local script_path = thisScript().path
        local tmp_path = script_path .. ".update"

        local file = io.open(tmp_path, "wb")
        if not file then
            es_msg("�� ������� ������� ��������� ���� ��� ����������!", "FF4444")
            return
        end
        file:write(result.data)
        file:close()

        local old_path = script_path .. ".old"
        os.remove(old_path)
        local renamed_old = os.rename(script_path, old_path)
        if not renamed_old then
            os.remove(tmp_path)
            es_msg("�� ������� �������� ���� ������� (��������, �� �����). ���������� ��������.", "FF4444")
            return
        end

        local renamed_new = os.rename(tmp_path, script_path)
        if not renamed_new then
            os.rename(old_path, script_path)
            es_msg("�� ������� ��������� ������ ����� �������. ���������� ��������.", "FF4444")
            return
        end

        update_available = false
        es_msg("���������� ������� �����������! ������������� ������ (������������� MoonLoader ��� ����), ����� ��������� ���.")
    end)
end

local function check_for_update()
    DC.spawn(function()
        local channel = effil.channel()
        local thr = DC.effil_start(version_check_worker, channel, VERSION_CHECK_URL)

        local result = wait_for_channel(channel, 15000, thr)
        if result and result.ok and result.version then
            if result.version ~= SCRIPT_VERSION then
                update_available      = true
                update_remote_version = result.version
                es_msg(string.format(
                    "�������� ���������� ({FFFF00}%s{FFFFFF} -> {FFFF00}%s{FFFFFF}). ������� �������������� ���������...",
                    SCRIPT_VERSION, result.version
                ), "FFFFFF")
                download_and_install_update()
            end
        end
    end)
end

DC.win_open = imgui_new.bool(false)

function DC.url_encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

function DC.open_browser()
    local hwid = get_hwid()
    if not hwid then
        es_msg("HWID ��� �� ��������. �������� ����� ���� ������.", "FFAA00")
        return
    end

    DC.spawn(function()
        local gen_result = try_worker_urls(gen_token_worker, function(url)
            return { WORKER_TOKEN, hwid, "discord" }
        end, 15000)

        if not gen_result or not gen_result.ok or not gen_result.token then
            local err = gen_result and gen_result.err or "timeout"
            if is_hwid_error(err) then
                notify_hwid_denied()
            else
                es_msg("�� ������� ����������� ������ �����������: " .. tostring(err), "FF4444")
            end
            return
        end

        local base = WORKER_URL_PRIMARY:gsub("/+$", "")
        local url = base .. "/discord-auth?token=" .. DC.url_encode(gen_result.token)

        local channel = effil.channel()
        local thr = DC.effil_start(open_url_worker, channel, url)

        local result = wait_for_channel(channel, 5000, thr)
        if not (result and result.ok) then
            copy_to_clipboard(url)
            es_msg("�� ������� ������� �������. ������ ����������� � ����� ������ � ������ � � �������.", "FF4444")
        else
            es_msg("�������� �������� ����������� Discord � ��������...")
        end
    end)
end

function DC.fetch_status()
    local hwid = get_hwid()
    if not hwid then return nil end
    return try_worker_urls(check_hwid_worker, function(url)
        return { hwid }
    end, 15000)
end

function DC.start_polling()
    if DC.polling then return end
    DC.polling = true

    DC.spawn(function()
        local waited = 0
        while DC.win_open[0] and waited < 600000 do
            wait(5000)
            waited = waited + 5000
            if not DC.win_open[0] then break end

            local r = DC.fetch_status()
            if r and r.ok and r.allowed and r.discord_linked then
                DC.linked = true
                DC.win_open[0] = false
                es_msg("Discord ������� ��������! ������ ������������ ���������.")

                espl_author_resolved    = false
                espl_panel.avatar_tries = 0
                resolve_espl_author()
                break
            end
        end
        DC.polling = false
    end)
end

function DC.require(fn)
    if DC.linked then
        fn()
        return
    end
    if DC.checking or DC.win_open[0] then return end

    if not get_hwid() then
        es_msg("HWID ��� �� ��������. �������� ����� ���� ������.", "FFAA00")
        return
    end

    DC.checking = true
    DC.spawn(function()
        local r = DC.fetch_status()
        DC.checking = false

        if not (r and r.ok) then
            es_msg("�� ������� ��������� �����������: " .. tostring(r and r.err or "timeout"), "FF4444")
            return
        end
        if not r.allowed then
            notify_hwid_denied()
            return
        end
        if r.discord_linked then
            DC.linked = true
            fn()
            return
        end

        DC.win_open[0] = true
        DC.start_polling()
    end)
end

sampRegisterChatCommand = function(name, handler)
    DC.raw_register(name, function(params)
        DC.require(function() handler(params) end)
    end)
end

imgui.OnFrame(function() return DC.win_open[0] end, function()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(18, 16))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 10))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.055, 0.075, 0.055, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(GREEN_BRIGHT))

    local io = imgui.GetIO()
    imgui.SetNextWindowPos(
        imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2),
        imgui.Cond.Always, imgui.ImVec2(0.5, 0.5)
    )
    imgui.SetNextWindowFocus()

    imgui.Begin('##discord_auth_window', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.AlwaysAutoResize)

    local W = 320

    center_text(u8("��������� �����������"), hexcol(GREEN_BRIGHT))
    imgui.Spacing()
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + W)
    imgui.TextWrapped(u8("����� ������������ EventScan, ������� ���� Discord-�������. ����� ������ ����, ����������� � �������� � ������� � ���� � ���� ��������� ����."))
    imgui.PopTextWrapPos()
    imgui.Spacing()

    if imgui.Button(u8("�������������� ����� Discord"), imgui.ImVec2(W, 34)) then
        DC.open_browser()
    end

    if DC.polling then
        center_text(u8("��� �������������..."), imgui.ImVec4(0.65, 0.75, 0.65, 1))
    end

    if imgui.Button(u8("�������"), imgui.ImVec2(W, 28)) then
        DC.win_open[0] = false
    end

    imgui.End()

    imgui.PopStyleColor(6)
    imgui.PopStyleVar(4)
end)

function parse_iso8601_utc(str)
    if type(str) ~= "string" then return nil end
    local y, m, d, h, mi, sec = str:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)")
    if not y then return nil end
    return {
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec)
    }
end

function utc_table_to_local_epoch(t)
    if not t then return nil end
    return espl_days_from_civil(t.year, t.month, t.day) * 86400
        + t.hour * 3600 + t.min * 60 + t.sec
end

function onScriptTerminate(scr, quit_game)
    if scr == thisScript() then
        scanning_active = false
        DC.cancel_all()
    end
end

function main()
    while not isSampAvailable() do wait(100) end

    resolve_screens_root(function(path)
        screens_root_folder = path
    end)

    resolve_hwid()
    resolve_espl_author()
    check_for_update()

    es_msg("{FFFF00}/es {FFFFFF}(�������� ����), {FFFF00}")
    es_msg("{FFFF00}/ess �������� ���_���������� {FFFFFF}(��������� �����)")
    es_msg("{FFFF00}/eslast {FFFFFF}(����� � ���������� ������)")
    es_msg("{FFFF00}/esr {FFFFFF}(������� CRM-������� ����� �������)")
    es_msg("{FFFF00}/esp {FFFFFF}(������� ����������� ������� � ����)")
    es_msg("{FFFF00}/esreset {FFFFFF}(�������� ��� ����� ����������)")

    sampRegisterChatCommand("es", function()
        start_detection_loop()

        capture_and_upload_screenshot(function(screen_url)
            if not screen_url then
                return
            end

            local lines = {
                string.format("--- ���� #%d | %s ---", #pending_reports + 1, get_readable_time()),
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
            es_msg("������� �����, ������ ����������. ������� ����������� {FFFF00}/es", "FFAA00")
            return
        end

        params = params or ""

        local words = {}
        for w in params:gmatch("%S+") do
            table.insert(words, w)
        end

        if #words < 2 then
            es_msg("�������������: {FFFF00}/ess �������� ������� ���_���������� {FFFFFF}(������: {FFFF00}/ess ������� ������� Nehto_Otto{FFFFFF})", "FF4444")
            return
        end

        local winner_nick = words[#words]
        if not winner_nick:find("_") then
            es_msg("��� ���������� ������ ���� ��������� ������ � ��������� ������ ������������� (��������: Nehto_Otto)", "FF4444")
            return
        end

        table.remove(words, #words)
        local event_name = table.concat(words, " ")
        if event_name == "" then
            es_msg("������� �������� ������� ����� ����� ����������", "FF4444")
            return
        end

        stop_detection_loop()
        local players_snapshot = unique_players_order
        unique_players       = {}
        unique_players_order = {}

        local author_nick = get_local_nickname()

        es_msg(string.format("�������� ��������� ������ (%d ������, %d �������) � ����... {FFFF00}�������: %s | ����������: %s | �����: %s", #pending_reports, #players_snapshot, event_name, winner_nick, author_nick))

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
                es_msg("�� ������� �������� ������ �� ����: " .. tostring(err), "FF4444")
                return
            end

            local utc_tbl = parse_iso8601_utc(date_str)
            if not utc_tbl then
                es_msg("�� ������� ��������� ���� ���������� ������", "FF4444")
                return
            end

            local last_epoch = utc_table_to_local_epoch(utc_tbl)
            if not last_epoch then
                es_msg("������ ������� �������", "FF4444")
                return
            end

            local diff = os.time() - last_epoch
            if diff < 0 then diff = 0 end

            local minutes = math.floor(diff / 60)
            local seconds = diff % 60

            if minutes < 1 then
                es_msg(string.format("� ���������� ������ ������: %d ���.", seconds))
            else
                es_msg(string.format("� ���������� ������ ������: %d ��� %d ���.", minutes, seconds))
            end
        end)
    end)

    sampRegisterChatCommand("esr", function()
        local hwid = get_hwid()
        if not hwid then
            es_msg("HWID ��� �� ��������. �������� ����� ���� ������.", "FFAA00")
            return
        end

        local nick = get_local_nickname()
        if not nick or nick == "Unknown" then
            es_msg("�� ������� ���������� ���� ���. �������� ��� ���.", "FF4444")
            return
        end

        DC.spawn(function()

            local gen_result = try_worker_urls(gen_token_worker, function(url)
                return { WORKER_TOKEN, hwid, "esr" }
            end, 15000)

            if not gen_result or not gen_result.ok or not gen_result.token then
                local err = gen_result and gen_result.err or "timeout"
                if is_hwid_error(err) then
                    notify_hwid_denied()
                else
                    es_msg("�� ������� ������������� ������ ��� �����: " .. tostring(err), "FF4444")
                end
                return
            end

            local url = "https://saportbati.github.io/eventCRM/author.html#/author/" .. nick .. "&token=" .. gen_result.token

            local channel = effil.channel()
            local thr = DC.effil_start(open_url_worker, channel, url)

            local result = wait_for_channel(channel, 5000, thr)
            if result and result.ok then
                es_msg("�������� ���� ������� � CRM ({FFFF00}" .. nick .. "{FFFFFF})...")
            else
                es_msg("�� ������� ������� ������� (" .. tostring(result and result.err or "timeout") .. ").", "FF4444")
                es_msg("������ ��� ������� �������� (��������� �� ������ 1 ������): {FFFF00}" .. url)
            end
        end)
    end)

    sampRegisterChatCommand("-esr", function()
        local hwid = get_hwid()
        if not hwid then
            es_msg("HWID ��� �� ��������. �������� ����� ���� ������.", "FFAA00")
            return
        end

        local nick = get_local_nickname()
        if not nick or nick == "Unknown" then
            es_msg("�� ������� ���������� ���� ���. �������� ��� ���.", "FF4444")
            return
        end

        DC.spawn(function()
            local gen_result = try_worker_urls(gen_token_worker, function(url)
                return { WORKER_TOKEN, hwid, "esr" }
            end, 15000)

            if not gen_result or not gen_result.ok or not gen_result.token then
                local err = gen_result and gen_result.err or "timeout"
                if is_hwid_error(err) then
                    notify_hwid_denied()
                else
                    es_msg("�� ������� ������������� ������ ��� �����: " .. tostring(err), "FF4444")
                end
                return
            end

            local url = "https://saportbati.github.io/eventCRM/author.html#/author/" .. nick .. "&token=" .. gen_result.token

            if copy_to_clipboard(url) then
                es_msg("������ ��� ����� ����������� � ����� ������ (��������� �� ������ 1 ������, {FFFF00}" .. nick .. "{FFFFFF}).")
            else
                es_msg("�� ������� ����������� � ����� ������. ������ (��������� �� ������ 1 ������): {FFFF00}" .. url, "FF4444")
            end
        end)
    end)

    sampRegisterChatCommand("esp", function()
        if espl_open[0] then
            espl_open[0]    = false
            espl_modal_open = false
            DC.esp_stop_polling()
            return
        end

        local hwid = get_hwid()
        if not hwid then
            es_msg("HWID ��� �� ��������. �������� ����� ���� ������.", "FFAA00")
            return
        end

        resolve_espl_author()

        espl_dates         = espl_get_date_range()
        espl_selected_date = format_date_ymd(os.time() + MSK_OFFSET)
        espl_schedule       = {}
        espl_top3            = {}
        espl_loading        = true
        espl_load_error      = ""
        espl_open[0]        = true

        DC.esp_start_polling(espl_selected_date)
    end)

    sampRegisterChatCommand("esreset", function()
        os.remove(SCREENS_CACHE_FILE)
        screens_root_folder = nil
        es_msg("��� ����� �� ����������� �������. �������� ���� ��� ��������� ���������...")
        resolve_screens_root(function(path)
            screens_root_folder = path
        end)
    end)

    wait(-1)
end