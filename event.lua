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

local SCRIPT_VERSION      = "0.1"
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

local SCRIPT_DIR    = thisScript().path:match("^(.*[\\/])") or ""
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

local function get_timestamp()
    local t = os.time() + 10800
    return os.date("!%Y-%m-%d_%H-%M-%S", t)
end

local function get_readable_time()
    local t = os.time() + 10800
    return os.date("!%d.%m.%Y %H:%M:%S", t)
end

local function parse_iso8601_utc(str)
    if not str then return nil end
    local y, mo, d, h, mi, se = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    return {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se)
    }
end

local function utc_table_to_local_epoch(tbl)
    local now = os.time()
    local utcdiff = os.difftime(now, os.time(os.date("!*t", now)))
    local ok, t = pcall(os.time, tbl)
    if not ok or not t then return nil end
    return t + utcdiff
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

local function try_worker_urls(worker_fn, build_args, timeout_ms)
    local function attempt(url)
        local channel = effil.channel()
        local args = build_args(url)
        local thr = effil.thread(worker_fn)(channel, url, unpack(args))
        active_threads[#active_threads+1] = thr
        return wait_for_channel(channel, timeout_ms)
    end

    local result = attempt(active_worker_url)
    if result and result.ok then
        return result
    end

    if active_worker_url ~= WORKER_URL_FALLBACK then
        print(string.format("[EventScan] Основной Worker (%s) не ответил: %s. Пробую резервный (%s)...",
            active_worker_url, tostring(result and result.err or "unknown_error"), WORKER_URL_FALLBACK))

        local fallback_result = attempt(WORKER_URL_FALLBACK)
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

local function draw_gradient_tag()
    for i, part in ipairs(TAG_GRADIENT) do
        if i > 1 then imgui.SameLine(0, 0) end
        imgui.TextColored(hexcol(part[2]), part[1])
    end
end

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

local function center_gradient_header(label_text)
    local total_w = 0
    for _, part in ipairs(TAG_GRADIENT) do
        total_w = total_w + imgui.CalcTextSize(part[1]).x
    end
    total_w = total_w + imgui.CalcTextSize(' ').x + imgui.CalcTextSize(label_text).x

    local avail_w = imgui.GetContentRegionAvail().x
    if total_w < avail_w then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail_w - total_w) / 2)
    end

    draw_gradient_tag()
    imgui.SameLine()
    imgui.Text(label_text)
end

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
        es_msg("Папка со скриншотами ещё не настроена — заполните открытое окно (или дождитесь автопоиска).", "FFAA00")
        return callback(nil)
    end
    if not get_hwid() then
        es_msg("HWID ещё определяется в фоне — попробуй через пару секунд.", "FFAA00")
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
                            es_msg("Сделал скриншот, отправляю его на сервер....")
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

        if not chat_notice_shown then
            es_msg("Сделал скриншот, отправляю его на сервер....")
        end

        if not target_file then
            es_msg("Скриншот не найден (тайм-аут)!", "FF4444")
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
            es_msg("Не удалось прочесть файл скриншота с диска!", "FF4444")
            return callback(nil)
        end
        local binary_data = file:read("*a")
        file:close()

        local hwid_value = get_hwid()
        local result = try_worker_urls(screenshot_upload_worker, function(url)
            return { WORKER_TOKEN, binary_data, hwid_value }
        end, 20000)
        if result and result.ok then
            callback(result.url)
        else
            local err = result and result.err or "timeout"
            if is_hwid_error(err) then
                notify_hwid_denied()
            else
                es_msg("Ошибка загрузки скриншота: " .. tostring(err), "FF4444")
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

    lua_thread.create(function()
        local result = try_worker_urls(d1_report_worker, function(url)
            return { WORKER_TOKEN, payload_json, hwid }
        end, 20000)
        if result and result.ok then
            es_msg("Отчёт успешно сохранён в базу данных!")
            if on_done then on_done(true) end
        else
            local err = result and result.err or "timeout"
            if is_hwid_error(err) then
                notify_hwid_denied()
            else
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
    check_for_update()

    es_msg("{FFFF00}/es {FFFFFF}(добавить скан), {FFFF00}")
    es_msg("{FFFF00}/ess Название Ник_Победителя {FFFFFF}(Отправить отчет)")
    es_msg("{FFFF00}/eslast {FFFFFF}(время с последнего отчёта)")
    es_msg("{FFFF00}/esr {FFFFFF}(открыть CRM-дашборд твоих отчётов)")
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
            es_msg(string.format("Скан добавлен в очередь (%d шт). Отправить всё: {FFFF00}/ess", #pending_reports))
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
        local nick = get_local_nickname()
        local url = "https://saportbati.github.io/eventCRM/author.html#/author/" .. nick

        local channel = effil.channel()
        local thr = effil.thread(open_url_worker)(channel, url)
        active_threads[#active_threads+1] = thr

        lua_thread.create(function()
            local result = wait_for_channel(channel, 5000)
            if result and result.ok then
                es_msg("Открываю CRM-дашборд: {FFFF00}" .. url)
            else
                es_msg("Не удалось открыть браузер (" .. tostring(result and result.err or "timeout") .. "). Ссылка: {FFFF00}" .. url, "FF4444")
            end
        end)
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
