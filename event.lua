local vkeys    = require("vkeys")
local lfs      = require("lfs")
local effil    = require("effil")
local encoding = require("encoding")
local dkjson   = require("dkjson")
local imgui    = require("mimgui")
local ffi      = require("ffi")

encoding.default = 'CP1251'
local u8 = encoding.UTF8

ES_REAL_WAIT = wait
ES_CUR = nil
function wait(ms)
    local cur = ES_CUR
    if cur and coroutine.running() == cur.co then
        return coroutine.yield(tonumber(ms) or 0)
    end
    return ES_REAL_WAIT(ms)
end

local function to_utf8(str)
    if not str or str == "" then return str end
    local ok, res = pcall(function() return u8:encode(str) end)
    if ok and res then return res end
    return str
end

local SCRIPT_DIR = thisScript().path:match("^(.*[\\/])") or ""

local DATA_DIR = SCRIPT_DIR .. "EventScan\\"
pcall(lfs.mkdir, DATA_DIR)

for _, name in ipairs({
    "eventscrin.ttf", "event_scan_reports.json", "screens_path_cache.txt",
    "hwid_cache.txt", "tp_last.txt", "tp_key.txt", "tp_pos.txt"
}) do
    local old_path, new_path = SCRIPT_DIR .. name, DATA_DIR .. name
    local fo = io.open(old_path, "rb")
    if fo then
        fo:close()
        local fn = io.open(new_path, "rb")
        if fn then
            fn:close()
        else
            pcall(os.rename, old_path, new_path)
        end
    end
end
pcall(os.remove, SCRIPT_DIR .. "espl_avatar.png")

local CUSTOM_FONT_URL   = "https://raw.githubusercontent.com/SaportBati/eventCRM/refs/heads/main/eventscrin.ttf"
local CUSTOM_FONT_FILE  = DATA_DIR .. "eventscrin.ttf"
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
    if DC and DC.trace then DC.trace("chat message: " .. tostring(text)) end
    sampAddChatMessage((DC and DC.tag or TAG) .. " {" .. body_color .. "}" .. text, (DC and DC.tag_color or 0x05ff12))
end

local WORKER_URL_PRIMARY  = "https://bitter-breeze-2c7b.vitadensikloh.workers.dev/"
local WORKER_URL_FALLBACK = "https://nehto--9aade89ea49811f1a9051607ee4eb77e.web.val.run"

local active_worker_url = WORKER_URL_PRIMARY
local SCAN_RADIUS  = 200.0

local SCRIPT_VERSION      = "1.91"
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

    es_handler    = nil,

}

DC.LOG_DIR   = DATA_DIR .. "logs\\"
DC.LOG_KEEP  = 10
DC.LOG_MAX   = 20 * 1024 * 1024
DC.LOG_FILE  = nil
DC.log_bytes = 0

DC.DEBUG_FILE = DATA_DIR .. "debug_mode.txt"
DC.DEBUG = false
do
    local f = io.open(DC.DEBUG_FILE, "r")
    if f then
        DC.DEBUG = (f:read("*a") or ""):find("1", 1, true) ~= nil
        f:close()
    end
end
function DC.debug_save()
    local f = io.open(DC.DEBUG_FILE, "w")
    if f then f:write(DC.DEBUG and "1" or "0") f:close() end
end

DC.TRACE_KEEP = { "ERROR", "WARNING", "TERMINATE", "=== EventScan", "script version", "moonloader",
    "jit:", "LAG:", "TIMEOUT", "FAILOVER", "EXCEPTION", "failed", "FAILED", "STALE", "overflow" }
function DC.trace(msg)
    if not DC.LOG_FILE or DC.log_bytes > DC.LOG_MAX then return end
    msg = tostring(msg)
    if not DC.DEBUG then
        local keep = false
        for _, k in ipairs(DC.TRACE_KEEP) do
            if msg:find(k, 1, true) then keep = true break end
        end
        if not keep then return end
    end
    msg = (msg:gsub("([A-Za-z]:\\[Uu]sers\\)[^\\]+", "%1<user>"))
    pcall(function()
        local line = string.format("%s [%9.3f] %s\n", os.date("%Y-%m-%d %H:%M:%S"), os.clock(), tostring(msg))
        if not DC.LOG_FH then DC.LOG_FH = io.open(DC.LOG_FILE, "ab") end
        local f = DC.LOG_FH
        if not f then return end
        f:write(line)
        f:flush()
        DC.log_bytes = DC.log_bytes + #line
        if DC.log_bytes > DC.LOG_MAX then
            f:write("LOG SIZE LIMIT REACHED, further lines are dropped\n")
            f:flush()
        end
    end)
end

DC.espl_trace_left = 0
DC.espl_frames = 0
DC.espl_tick_t = 0
function DC.espl_tick()
    DC.espl_frames = DC.espl_frames + 1
    local now = os.clock()
    if now - DC.espl_tick_t >= 0.5 then
        DC.espl_tick_t = now
        DC.trace(string.format("espl tick frames=%d mem=%.0fKB egc=%s", DC.espl_frames, collectgarbage("count"), DC.egc_info()))
    end
end

function DC.num(v)
    if type(v) == "number" then return v end
    return tonumber(v) or 0
end
function DC.str(v)
    if type(v) == "string" then return v end
    return nil
end
function DC.clean_top3(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, e in ipairs(list) do
        if type(e) == "table" and #out < 8 then
            out[#out + 1] = { author = DC.str(e.author) or "-", count = DC.num(e.count) }
        end
    end
    return out
end
function DC.ftrace(msg)
    if (DC.espl_trace_left or 0) > 0 then DC.trace("espl frame: " .. msg) end
end

function DC.print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local s = table.concat(parts, "\t")
    print(s)
    DC.trace("print: " .. s)
end

function DC.log_init()
    pcall(lfs.mkdir, DC.LOG_DIR)
    os.remove(DATA_DIR .. "trace.log")

    local files = {}
    local okd, iter, obj = pcall(lfs.dir, DC.LOG_DIR)
    if okd and iter then
        for name in iter, obj do
            if name:match("^log_.+%.log$") then files[#files + 1] = name end
        end
    end
    table.sort(files)

    local prev_note
    if #files > 0 then
        local f = io.open(DC.LOG_DIR .. files[#files], "rb")
        if f then
            local size = f:seek("end") or 0
            f:seek("set", math.max(size - 8192, 0))
            local tail = f:read("*a") or ""
            f:close()
            if not tail:find("SCRIPT TERMINATE", 1, true) then
                prev_note = "PREVIOUS SESSION " .. files[#files] .. " HAS NO TERMINATE MARK -> game or script probably crashed"
            end
        end
    end

    while #files > DC.LOG_KEEP - 1 do
        os.remove(DC.LOG_DIR .. files[1])
        table.remove(files, 1)
    end

    local function exists(path)
        local f = io.open(path, "rb")
        if f then f:close() return true end
        return false
    end
    local base = DC.LOG_DIR .. os.date("log_%Y%m%d_%H%M%S")
    local path = base .. ".log"
    local n = 1
    while exists(path) do
        n = n + 1
        path = base .. "_" .. n .. ".log"
    end
    DC.LOG_FILE = path

    DC.trace("=== EventScan log started ===")
    DC.trace("script version: " .. tostring(SCRIPT_VERSION))
    DC.trace("script path: " .. tostring(pcall(function() return thisScript().path end) and thisScript().path or "?"))
    local okm, mlv = pcall(getMoonloaderVersion)
    DC.trace("moonloader version: " .. tostring(okm and mlv or "?"))
    DC.trace("jit: " .. tostring(jit and jit.version or "?") .. " os=" .. tostring(jit and jit.os or "?"))
    DC.trace(string.format("lua memory: %.0f KB", collectgarbage("count")))
    DC.trace("log files kept: " .. (#files + 1) .. " (max " .. DC.LOG_KEEP .. ")")
    if prev_note then DC.trace("WARNING: " .. prev_note) end
end
pcall(DC.log_init)

DC.ethread_meta = setmetatable({}, { __mode = "k" })
DC.in_flight    = DC.in_flight or {}
DC.in_flight_t  = {}
DC.worker_names = {}

function DC.worker_name(fn)
    local n = DC.worker_names[fn]
    if n then return n end
    local line = "?"
    pcall(function() line = "worker@" .. tostring(debug.getinfo(fn, "S").linedefined) end)
    return line
end

function DC.heartbeat_start()
    DC.spawn(function()
        local n = 0
        local t_prev = os.clock()
        while true do
            wait(5000)
            n = n + 1
            local now = os.clock()
            local dt = now - t_prev
            t_prev = now
            if dt > 7.5 then
                DC.trace(string.format("LAG: heartbeat expected 5.0s but took %.2fs (game/script thread was blocked)", dt))
            end
            local active = DC.tp_timer.visible or (DC.bank and DC.bank.state ~= "idle")
            if active or n % 6 == 0 or dt > 7.5 then
                local gs = "?"
                if type(sampGetGamestate) == "function" then
                    local ok, v = pcall(sampGetGamestate)
                    gs = ok and tostring(v) or "err"
                end
                local counts = {}
                for _, thr in ipairs(DC.ethreads) do
                    local ok, st = pcall(function() return thr:status() end)
                    local k = ok and tostring(st) or "err"
                    counts[k] = (counts[k] or 0) + 1
                end
                local cs = {}
                for k, v in pairs(counts) do cs[#cs + 1] = k .. "=" .. v end
                table.sort(cs)
                DC.trace(string.format(
                    "heartbeat: mem=%.0fKB lthreads=%d ethreads=%d [%s] inflight=%d tp_visible=%s bank=%s scans=%d reports=%d players=%d gamestate=%s egc=%s",
                    collectgarbage("count"), #DC.lthreads, #DC.ethreads, table.concat(cs, ","), DC.inflight,
                    tostring(DC.tp_timer.visible), tostring(DC.bank and DC.bank.state),
                    #pending_scans, #pending_reports, #unique_players_order, gs, DC.egc_info()))
            end
        end
    end)
end

DC.tasks = DC.lthreads

function DC.spawn(fn, ...)
    local args, nargs = { ... }, select("#", ...)
    DC.sseq = (DC.sseq or 0) + 1
    local sid = DC.sseq
    local src = "?"
    pcall(function()
        local i = debug.getinfo(2, "Sl")
        src = tostring(i.short_src):match("[^\\/]+$") .. ":" .. tostring(i.currentline)
    end)
    DC.trace(string.format("LTHREAD#%d SPAWN from=%s alive_list=%d", sid, src, #DC.tasks))
    local t0 = os.clock()
    local task = { sid = sid, src = src, t0 = t0, wake = 0, dead = false }
    task.co = coroutine.create(function() return fn(unpack(args, 1, nargs)) end)
    DC.tasks[#DC.tasks + 1] = task
    return task
end

function DC.sched_step()
    local list = DC.tasks
    local n = #list
    for i = 1, n do
        local t = list[i]
        if t and not t.dead and os.clock() * 1000 >= t.wake then
            ES_CUR = t
            local ok, r = coroutine.resume(t.co)
            ES_CUR = nil
            if not ok then
                t.dead = true
                local err = debug.traceback(t.co, tostring(r))
                DC.trace(string.format("LTHREAD#%d (from %s) ERROR after %.2fs: %s", t.sid, t.src, os.clock() - t.t0, err))
                print("[EventScan] thread error: " .. tostring(r))
            elseif coroutine.status(t.co) == "dead" then
                t.dead = true
                DC.trace(string.format("LTHREAD#%d (from %s) DONE in %.2fs", t.sid, t.src, os.clock() - t.t0))
            else
                t.wake = os.clock() * 1000 + (tonumber(r) or 0)
            end
        end
    end
    for i = #list, 1, -1 do
        if list[i].dead then table.remove(list, i) end
    end
end

function DC.reap()
    pcall(DC.pool_poll)
    local list = DC.ethreads
    for i = #list, 1, -1 do
        local thr = list[i]
        local ok, status, err = pcall(function() return thr:status() end)
        local meta = DC.ethread_meta[thr]
        local id = meta and meta.id or "?"
        local nm = meta and meta.name or "?"
        local life = meta and (os.clock() - meta.t) or -1
        if not ok then
            DC.trace(string.format("ETHREAD#%s[%s] REAP status() threw: %s", tostring(id), nm, tostring(status)))
            table.remove(list, i)
        elseif status == "completed" or status == "cancelled" or status == "failed" then
            DC.trace(string.format("ETHREAD#%s[%s] REAP status=%s err=%s lifetime=%.2fs left=%d",
                tostring(id), nm, tostring(status), tostring(err), life, #list - 1))
            if status == "failed" then
                DC.print("[EventScan] effil thread failed: " .. tostring(err))
            end
            if meta and DC.pool then DC.pool.finished[meta.id] = nil end
            table.remove(list, i)
        end
    end
end

function DC.egc_info()
    local ok, c = pcall(function() return effil.gc and effil.gc.count and effil.gc.count() end)
    return ok and tostring(c) or "err"
end

DC.egc_paused = false
if effil.gc and effil.gc.pause then
    DC.egc_paused = pcall(effil.gc.pause)
end
DC.trace("effil.gc available=" .. tostring(effil.gc ~= nil) .. " paused=" .. tostring(DC.egc_paused) .. " count=" .. DC.egc_info())

function DC.effil_gc_loop()
    DC.spawn(function()
        while true do
            wait(5000)
            DC.reap()
            if not (DC.espl_open_ref and DC.espl_open_ref[0]) and DC.inflight == 0 and #DC.ethreads == 0 then
                local before = DC.egc_info()
                collectgarbage()
                collectgarbage()
                if effil.gc and effil.gc.collect then pcall(effil.gc.collect) end
                local after = DC.egc_info()
                if before ~= after then
                    DC.trace("effil gc: idle collect " .. before .. " -> " .. after)
                end
            end
        end
    end)
end

DC.POOL_MIN = 2
DC.POOL_MAX = 8
DC.pool     = { jobs = nil, done = nil, threads = {}, busy = 0, finished = {} }

function DC.pool_main(jobs, done, log_path, index)
    local current = "idle"
    local function wl(m)
        if not log_path or log_path == "" then return end
        pcall(function()
            local f = io.open(log_path, "ab")
            if f then
                f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [pool#" .. tostring(index) .. ":" .. tostring(current) .. "] " .. tostring(m) .. "\n")
                f:close()
            end
        end)
    end
    local function now()
        local ok, sock = pcall(require, "socket")
        if ok and type(sock) == "table" and sock.gettime then return sock.gettime() end
        return os.time()
    end
    local function hdrs(h)
        if type(h) ~= "table" then return "-" end
        local out = {}
        for k, v in pairs(h) do
            local kl = tostring(k):lower()
            if kl == "x-hwid" or kl == "x-auth-token" then out[#out + 1] = tostring(k) .. "=<set>"
            else out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
        end
        table.sort(out)
        return table.concat(out, "; ")
    end
    local function call(method, url, opts, fn)
        opts = type(opts) == "table" and opts or {}
        local blen = opts.data and #tostring(opts.data) or 0
        wl(string.format("HTTP >> %s %s timeout=%s body_len=%d headers{%s}", method, tostring(url), tostring(opts.timeout), blen, hdrs(opts.headers)))
        local t0 = now()
        local ok, res = pcall(fn)
        local dt = now() - t0
        if not ok then
            wl(string.format("HTTP !! %s %s EXCEPTION after %.2fs: %s", method, tostring(url), dt, tostring(res)))
            error(res, 0)
        end
        if type(res) == "table" then
            local text = res.text
            local tl = type(text) == "string" and #text or -1
            local preview = ""
            if type(text) == "string" and not text:find("[%z\1-\8\14-\31]")
               and (tl <= 400 or tonumber(res.status_code) ~= 200) then
                preview = " body=" .. (text:sub(1, 300):gsub("[\r\n]+", " "))
            end
            wl(string.format("HTTP << %s %s status=%s body_len=%d time=%.2fs%s", method, tostring(url), tostring(res.status_code), tl, dt, preview))
        else
            wl(string.format("HTTP << %s %s result=%s time=%.2fs", method, tostring(url), tostring(res), dt))
        end
        return res
    end

    wl("POOL THREAD started")
    local okr, req = pcall(require, "requests")
    if okr and type(req) == "table" then
        pcall(function()
            local w = setmetatable({}, { __index = req })
            w.get = function(url, opts) return call("GET", url, opts, function() return req.get(url, opts) end) end
            w.request = function(method, url, opts)
                return call(tostring(method), url, opts, function() return req.request(method, url, opts) end)
            end
            package.loaded["requests"] = w
        end)
    else
        wl("requests module NOT available: " .. tostring(req))
    end

    while true do
        local id, name, bytes, args = jobs:pop(5)
        if id == false then
            wl("POOL THREAD stop requested")
            return
        end
        if id ~= nil then
            current = tostring(name)
            wl("JOB#" .. tostring(id) .. " start")
            local a = {}
            for i = 1, (args and args.n or 0) do a[i] = args[i] end
            local n = args and args.n or 0
            local fn, lerr = loadstring(bytes)
            if not fn then
                wl("JOB#" .. tostring(id) .. " loadstring failed: " .. tostring(lerr))
                pcall(function() a[1]:push({ ok = false, err = "worker_failed: loadstring " .. tostring(lerr) }) end)
            else
                local ok, err = pcall(fn, unpack(a, 1, n))
                if ok then
                    wl("JOB#" .. tostring(id) .. " end ok")
                else
                    wl("JOB#" .. tostring(id) .. " EXCEPTION: " .. tostring(err))
                    pcall(function() a[1]:push({ ok = false, err = "worker_failed: " .. tostring(err) }) end)
                end
            end
            a = nil
            args = nil
            bytes = nil
            current = "idle"
            done:push(id)
        end
    end
end

function DC.pool_poll()
    local P = DC.pool
    if not P.done then return end
    for _ = 1, 32 do
        local id = P.done:pop(0)
        if id == nil then break end
        P.finished[id] = true
        P.busy = math.max(P.busy - 1, 0)
    end
end

function DC.pool_stop()
    local P = DC.pool
    if not P.jobs then return end
    for _ = 1, #P.threads do pcall(function() P.jobs:push(false) end) end
    DC.trace("POOL stop sentinels sent to " .. #P.threads .. " threads")
end

function DC.pool_submit(fn, name, eid, ...)
    local okd, bytes = pcall(string.dump, fn)
    if not okd or not bytes then error("pool: string.dump failed: " .. tostring(bytes), 0) end
    local P = DC.pool
    if not P.jobs then
        P.jobs = effil.channel()
        P.done = effil.channel()
        DC.trace("POOL channels created")
    end
    DC.pool_poll()
    local want = math.min(math.max(P.busy + 1, DC.POOL_MIN), DC.POOL_MAX)
    while #P.threads < want do
        local idx = #P.threads + 1
        local t = effil.thread(DC.pool_main)(P.jobs, P.done, DC.DEBUG and DC.LOG_FILE or "", idx)
        P.threads[idx] = t
        DC.trace(string.format("POOL spawned thread #%d (total=%d busy=%d)", idx, #P.threads, P.busy))
    end
    local n = select("#", ...)
    local args = { n = n, ... }
    P.busy = P.busy + 1
    P.jobs:push(eid, name, bytes, args)
    DC.trace(string.format("POOL job#%d [%s] queued: bytecode=%d busy=%d threads=%d", eid, name, #bytes, P.busy, #P.threads))
    local job = {}
    function job:status()
        DC.pool_poll()
        return P.finished[eid] and "completed" or "running"
    end
    function job:cancel()
        DC.trace(string.format("POOL job#%d cancel requested: pooled jobs cannot be cancelled, thread stays busy until the request returns", eid))
    end
    DC.ethreads[#DC.ethreads + 1] = job
    DC.ethread_meta[job] = { id = eid, name = name, t = os.clock() }
    return job
end

function DC.effil_start(fn, ...)
    DC.reap()
    local name = DC.worker_name(fn)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = DC.sum((select(i, ...))) end
    DC.eseq = (DC.eseq or 0) + 1
    local eid = DC.eseq
    do
        DC.net_args = DC.net_args or {}
        local ps, url = {}, nil
        for i = 1, n do
            local v = (select(i, ...))
            if type(v) == "string" and v:match("^https?://") then
                local masked = v:gsub("%?.*$", "?<...>")
                url = url or masked
                ps[i] = masked
            else
                ps[i] = DC.sum(v, 80)
            end
        end
        DC.net_args[eid] = { args = table.concat(ps, ", "), url = url }
    end
    DC.trace(string.format("ETHREAD#%d START worker=%s args=(%s) ethreads_before=%d inflight=%d egc=%s mem=%.0fKB",
        eid, name, table.concat(parts, ", "), #DC.ethreads, DC.inflight, DC.egc_info(), collectgarbage("count")))
    return DC.pool_submit(fn, name, eid, ...)
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

function DC.esp_wait_worker(channel, worker_url, hwid, date, version, log_path)
    local function wlog(m)
        if not log_path then return end
        pcall(function()
            local f = io.open(log_path, "ab")
            if f then
                f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [worker:esp_wait] " .. tostring(m) .. "\n")
                f:close()
            end
        end)
    end
    wlog("start version=" .. tostring(version))
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

    wlog("request begin")
    local qs = "date=" .. date .. "&version=" .. url_encode(version or "")
    local ok, resp = pcall(requests.get, worker_url .. "/esp/wait?" .. qs, {
        headers = {
            ["X-HWID"]     = hwid,
            ["User-Agent"] = "SAMP-EventScan/1.4"
        },
        timeout = 28
    })

    wlog("request returned ok=" .. tostring(ok) .. " status=" .. tostring(ok and resp and resp.status_code))
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

    local function clean(v, depth)
        local t = type(v)
        if t == "string" or t == "number" or t == "boolean" then return v end
        if t ~= "table" or depth > 6 then return nil end
        local out = {}
        for k, x in pairs(v) do
            local tk = type(k)
            if tk == "string" or tk == "number" then
                local c = clean(x, depth + 1)
                if c ~= nil then out[k] = c end
            end
        end
        return out
    end
    data = clean(data, 0) or { ok = false, err = "json_parse_fail" }
    wlog("json ok, pushing result")
    channel:push(data)
    wlog("pushed, thread ends")
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

local LOCAL_DB_FILE  = DATA_DIR .. "event_scan_reports.json"
local SCREENS_CACHE_FILE = DATA_DIR .. "screens_path_cache.txt"
local HWID_CACHE_FILE = DATA_DIR .. "hwid_cache.txt"

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
                        DC.trace('new player in radius: ' .. tostring(name) .. ' (total ' .. #unique_players_order .. ')')
                    end
                end
            end
        end
    end
end

local function start_detection_loop()
    if scanning_active then return end
    DC.trace('player detection loop started')
    scanning_active = true
    DC.spawn(function()
        while scanning_active do
            scan_nearby_players_once()
            wait(DETECTION_POLL_INTERVAL)
        end
    end)
end

local function stop_detection_loop()
    DC.trace('player detection loop stopped, unique players=' .. tostring(#unique_players_order))
    scanning_active = false
end

local function get_readable_time()
    local t = os.time() + 10800
    return os.date("!%d.%m.%Y %H:%M:%S", t)
end

local DOW_LABELS_RU = { "Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб" }

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
    if not date_str or not time_str then return 0 end
    local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
    local h, mi = time_str:match("(%d+):(%d+)")
    if not y or not m or not d or not h or not mi then return 0 end
    local days = espl_days_from_civil(tonumber(y), tonumber(m), tonumber(d))
    local naive_msk_epoch = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60
    return naive_msk_epoch - MSK_OFFSET
end

local function espl_is_past(date_str, time_str)
    if not date_str or not time_str then return true end
    return espl_slot_epoch(date_str, time_str) < os.time()
end

local function is_dir(path)
    local ok, attr = pcall(lfs.attributes, path)
    return ok and attr and attr.mode == "directory"
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
            if hMem == ffi.NULL then error("alloc_fail") end

            local ptr = kernel32.GlobalLock(hMem)
            if ptr == ffi.NULL then error("lock_fail") end

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

local function screenshot_upload_worker(channel, worker_url, binary_data, hwid, log_path)
    local function wlog(m)
        if not log_path then return end
        pcall(function()
            local f = io.open(log_path, "ab")
            if f then
                f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [worker:upload] " .. tostring(m) .. "\n")
                f:close()
            end
        end)
    end
    wlog("start, bytes=" .. tostring(binary_data and #binary_data))
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
    wlog("base64 done, len=" .. #b64 .. " mime=" .. tostring(ok_m))

    local payload = '{"data":"' .. b64 .. '"}'
    b64 = nil
    wlog("payload built, len=" .. #payload)

    wlog("sending request")
    local ok, response = pcall(requests.request, "POST", worker_url .. "/upload-image", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload,
        timeout = 25
    })

    wlog("request returned ok=" .. tostring(ok) .. " status=" .. tostring(ok and response and response.status_code))
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

local function d1_report_worker(channel, worker_url, payload_json, hwid)
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

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/report", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload_json,
        timeout = 25
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

local function gen_token_worker(channel, worker_url, hwid, purpose)
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

    local payload = json.encode({ purpose = purpose or "esr" })

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/gen-token", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload,
        timeout = 25
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

local function d1_last_report_worker(channel, worker_url)
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

    local ok, resp = pcall(requests.get, worker_url .. "/last", {
        headers = {
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        timeout = 15
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

    local ok, resp = pcall(requests.get, worker_url .. "/plan?date=" .. date, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" },
        timeout = 20
    })

    if not ok or not resp then
        channel:push({ ok = false, err = "network_fail" })
        return
    end

    if resp.status_code == 200 then
        local pok, data = pcall(json.decode, resp.text)
        if pok and data and data.ok then
            local function clean(v, depth)
                local t = type(v)
                if t == "string" or t == "number" or t == "boolean" then return v end
                if t ~= "table" or depth > 6 then return nil end
                local out = {}
                for k, x in pairs(v) do
                    local tk = type(k)
                    if tk == "string" or tk == "number" then
                        local c = clean(x, depth + 1)
                        if c ~= nil then out[k] = c end
                    end
                end
                return out
            end
            channel:push({ ok = true, slots = clean(data.slots, 0) or {} })
        else
            channel:push({ ok = false, err = "json_parse_fail" })
        end
    else
        channel:push({ ok = false, err = "http_" .. tostring(resp.status_code) })
    end
end

local function plan_save_worker(channel, worker_url, hwid, date, time, title)
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

    local payload = json.encode({ date = date, time = time, title = title })

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/plan", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload,
        timeout = 25
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

    local payload = json.encode({ date = date, time = time })

    local ok, resp = pcall(requests.request, "POST", worker_url .. "/plan/delete", {
        headers = {
            ["Content-Type"] = "application/json",
            ["X-HWID"]       = hwid,
            ["User-Agent"]   = "SAMP-EventScan/1.4"
        },
        data = payload,
        timeout = 25
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

    local ok, resp = pcall(requests.get, worker_url .. "/check-hwid", {
        headers = {
            ["X-HWID"]     = hwid,
            ["User-Agent"] = "SAMP-EventScan/1.4"
        },
        timeout = 15
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

    local ok, resp = pcall(requests.get, worker_url .. "/my-stats", {
        headers = {
            ["X-HWID"]     = hwid,
            ["User-Agent"] = "SAMP-EventScan/1.4"
        },
        timeout = 15
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
    local ok_r, requests = pcall(require, "requests")
    if not ok_r or not requests then
        channel:push({ ok = false, err = "no_requests" })
        return
    end

    local ok, resp = pcall(requests.get, url, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" },
        timeout = 20
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
    local ok_r, requests = pcall(require, "requests")
    if not ok_r or not requests then
        channel:push({ ok = false, err = "no_requests" })
        return
    end

    local ok, resp = pcall(requests.get, url, {
        headers = { ["User-Agent"] = "SAMP-EventScan/1.4" },
        timeout = 20
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

    pcall(function()
        ffi.cdef[[
            void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile,
                                 const char* lpParameters, const char* lpDirectory, int nShowCmd);
        ]]
    end)

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

function DC.wait_raw(channel, timeout_ms, thr, tag)
    tag = tag or "wait_for_channel"
    local meta = thr and DC.ethread_meta[thr]
    local eid  = meta and meta.id or "?"
    local waited, POLL = 0, 30
    local t0 = os.clock()
    local last_status, last_note, polls = nil, t0, 0
    DC.trace(string.format("%s WAIT begin ETHREAD#%s timeout=%dms", tag, tostring(eid), timeout_ms))

    while waited < timeout_ms do
        polls = polls + 1
        local data = channel:pop(0)
        if data ~= nil then
            DC.trace(string.format("%s WAIT ETHREAD#%s got result after %.0fms (polls=%d) %s",
                tag, tostring(eid), (os.clock() - t0) * 1000, polls, DC.sumr(data)))
            return data
        end

        if thr then
            local ok, status, err = pcall(function() return thr:status() end)
            if ok and status ~= last_status then
                DC.trace(string.format("%s WAIT ETHREAD#%s status %s -> %s (+%.0fms)",
                    tag, tostring(eid), tostring(last_status), tostring(status), (os.clock() - t0) * 1000))
                last_status = status
            end
            if ok and (status == "failed" or status == "completed" or status == "cancelled") then
                local last = channel:pop(0)
                if last ~= nil then
                    DC.trace(tag .. " WAIT thread finished, late result: " .. DC.sumr(last))
                    return last
                end
                DC.trace(string.format("%s WAIT thread finished (%s) WITHOUT result, err=%s", tag, tostring(status), tostring(err)))
                if status == "failed" then
                    return { ok = false, err = "worker_failed: " .. tostring(err) }
                end
                return { ok = false, err = "worker_no_result" }
            end
        end

        if os.clock() - last_note >= 2 then
            last_note = os.clock()
            DC.trace(string.format("%s WAIT still waiting ETHREAD#%s status=%s real=%.1fs nominal=%.1fs/%.1fs",
                tag, tostring(eid), tostring(last_status), os.clock() - t0, waited / 1000, timeout_ms / 1000))
        end

        wait(POLL)
        waited = waited + POLL
    end

    DC.trace(string.format("%s WAIT TIMEOUT ETHREAD#%s real=%.2fs nominal=%dms last_status=%s",
        tag, tostring(eid), os.clock() - t0, timeout_ms, tostring(last_status)))
    if thr then
        local okc, errc = pcall(function() thr:cancel(0) end)
        local ok2, st2 = pcall(function() return thr:status() end)
        DC.trace(string.format("%s WAIT cancel(0) ok=%s err=%s status_after=%s", tag, tostring(okc), tostring(errc), ok2 and tostring(st2) or "err"))
    end
    local drained = 0
    pcall(function()
        for _ = 1, 8 do
            local leftover = channel:pop(0)
            if leftover == nil then break end
            drained = drained + 1
        end
    end)
    DC.trace(tag .. " WAIT drained leftovers=" .. drained)
    return nil
end

DC.net = { log = {}, seq = 0 }

function DC.net_record(thr, tag, timeout_ms, res, ms)
    local meta = thr and DC.ethread_meta[thr]
    local info
    if meta and DC.net_args then
        info = DC.net_args[meta.id]
        DC.net_args[meta.id] = nil
    end
    local status = "OK"
    if res == nil then status = "TIMEOUT" elseif not res.ok then status = "FAIL" end
    local function clean(v) return (tostring(v):gsub("[%c]", " ")) end
    DC.net.seq = DC.net.seq + 1
    local log = DC.net.log
    log[#log + 1] = {
        id     = DC.net.seq,
        time   = os.date("%H:%M:%S"),
        name   = (meta and meta.name) or "?",
        url    = (info and info.url) or "-",
        tag    = clean(tag or "-"),
        ms     = ms,
        tmo    = timeout_ms,
        status = status,
        args   = clean((info and info.args) or "-"),
        result = res == nil and "no result (timeout)" or clean(DC.sumr(res)),
    }
    if #log > 200 then table.remove(log, 1) end
end

local function wait_for_channel(channel, timeout_ms, thr, tag)
    local t0 = os.clock()
    local res = DC.wait_raw(channel, timeout_ms, thr, tag)
    pcall(DC.net_record, thr, tag, timeout_ms, res, (os.clock() - t0) * 1000)
    return res
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

local function try_worker_urls(worker_fn, build_args, timeout_ms, op_key)
    DC.req_seq = (DC.req_seq or 0) + 1
    local rid   = DC.req_seq
    local wname = DC.worker_name(worker_fn)
    local tag   = string.format("REQ#%d[%s]", rid, wname)
    local t_all = os.clock()

    DC.trace(string.format("%s BEGIN op_key=%s timeout=%sms active_url=%s ctx{%s}",
        tag, tostring(op_key), tostring(timeout_ms), tostring(active_worker_url), DC.ctx()))

    if op_key and DC.in_flight[op_key] then
        local age = os.clock() - (DC.in_flight_t[op_key] or 0)
        if age < 60 then
            DC.trace(string.format("%s DROP single-flight op_key=%s lock_age=%.1fs", tag, tostring(op_key), age))
            return { ok = false, err = "inflight_dedup" }
        end
        DC.trace(string.format("%s STALE single-flight lock op_key=%s age=%.1fs -> overriding", tag, tostring(op_key), age))
    end
    if op_key then
        DC.in_flight[op_key]   = true
        DC.in_flight_t[op_key] = os.clock()
    end

    local function finish(res)
        if op_key then
            DC.in_flight[op_key]   = nil
            DC.in_flight_t[op_key] = nil
        end
        DC.trace(string.format("%s END total=%.2fs result=%s ctx{%s}", tag, os.clock() - t_all, DC.sumr(res), DC.ctx()))
        return res
    end

    local function attempt(url, attempt_timeout_ms, label)
        local atag = tag .. " " .. label
        local guard = 0
        while DC.inflight >= DC.MAX_INFLIGHT and guard < 200 do
            if guard == 0 then
                DC.trace(string.format("%s waiting for free inflight slot (inflight=%d/%d)", atag, DC.inflight, DC.MAX_INFLIGHT))
            end
            wait(50)
            guard = guard + 1
        end
        if guard > 0 then DC.trace(string.format("%s slot wait finished: %dms", atag, guard * 50)) end
        if guard >= 200 then
            DC.trace(atag .. " inflight guard overflow, dropping request")
            return { ok = false, err = "inflight_overflow" }
        end
        DC.inflight = DC.inflight + 1
        local t_start = os.clock()

        local result
        local ok_args, args = pcall(build_args, url)
        if not ok_args or type(args) ~= "table" then
            DC.trace(atag .. " build_args FAILED: " .. tostring(args))
            result = { ok = false, err = "thread_start_fail: bad_args" }
        else
            local parts = {}
            for i = 1, #args do parts[i] = DC.sum(args[i]) end
            DC.trace(string.format("%s START url=%s timeout=%dms args(%d)=[%s]", atag, tostring(url), attempt_timeout_ms, #args, table.concat(parts, ", ")))
            local channel = effil.channel()
            local ok_start, thr = pcall(function()
                return DC.effil_start(worker_fn, channel, url, unpack(args))
            end)
            DC.trace(atag .. " thread start ok=" .. tostring(ok_start) .. (ok_start and "" or (" err=" .. tostring(thr))))
            if ok_start then
                result = wait_for_channel(channel, attempt_timeout_ms, thr, atag)
            else
                result = { ok = false, err = "thread_start_fail: " .. tostring(thr) }
            end
        end

        DC.inflight = math.max(DC.inflight - 1, 0)
        collectgarbage("step", 100)
        DC.trace(string.format("%s ATTEMPT DONE time=%.2fs result=%s inflight=%d mem=%.0fKB egc=%s",
            atag, os.clock() - t_start, DC.sumr(result), DC.inflight, collectgarbage("count"), DC.egc_info()))
        return result
    end

    if active_worker_url == WORKER_URL_FALLBACK and DC.fallback_since
       and os.clock() - DC.fallback_since > 120 then
        DC.trace(tag .. " fallback window expired, returning to primary worker")
        active_worker_url = WORKER_URL_PRIMARY
    end

    local has_fallback    = active_worker_url ~= WORKER_URL_FALLBACK
    local primary_timeout = has_fallback
        and math.min(math.max(PRIMARY_WORKER_TIMEOUT_MS, math.floor(timeout_ms * 0.7)), timeout_ms)
        or timeout_ms
    DC.trace(string.format("%s PLAN has_fallback=%s primary_timeout=%dms", tag, tostring(has_fallback), primary_timeout))

    local result = attempt(active_worker_url, primary_timeout, "primary")
    if result and result.ok then
        return finish(result)
    end

    if has_fallback and is_network_failure(result) then
        DC.trace(tag .. " FAILOVER to fallback, reason=" .. DC.sumr(result))
        DC.print(string.format("[EventScan] Основной Worker (%s) не ответил: %s. Пробую резервный (%s)...",
            active_worker_url, tostring(result and result.err or "timeout"), WORKER_URL_FALLBACK))

        local fallback_result = attempt(WORKER_URL_FALLBACK, timeout_ms, "fallback")
        if fallback_result and fallback_result.ok then
            active_worker_url = WORKER_URL_FALLBACK
            DC.fallback_since = os.clock()
            DC.print(string.format("[EventScan] Резервный Worker (%s) сработал. Переключаюсь на него до конца сессии.", WORKER_URL_FALLBACK))
            return finish(fallback_result)
        end

        DC.print(string.format("[EventScan] Резервный Worker (%s) тоже не ответил: %s.",
            WORKER_URL_FALLBACK, tostring(fallback_result and fallback_result.err or "timeout")))
        return finish(fallback_result or result)
    end

    DC.trace(string.format("%s no failover (has_fallback=%s network_failure=%s)", tag, tostring(has_fallback), tostring(is_network_failure(result))))
    return finish(result)
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

        local ok_a, attr = pcall(lfs.attributes, chatlog_path)
        local size = (ok_a and attr) and attr.size or 0
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

    local ok_a, attr = pcall(lfs.attributes, chatlog_path)
    local baseline_size = (ok_a and attr) and attr.size or 0

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

DC.THEME_FILE    = DATA_DIR .. "theme_color.txt"
DC.THEME_DEFAULT = { 0x05 / 255, 1.0, 0x12 / 255 }
DC.theme         = { DC.THEME_DEFAULT[1], DC.THEME_DEFAULT[2], DC.THEME_DEFAULT[3] }
DC.theme_dirty   = false
DC.theme_n       = { 0.02, 1.0, 0.07 }

function DC.tc(r, g, b, a)
    local mx = math.max(r, g, b)
    if mx <= 0 then return imgui.ImVec4(r, g, b, a or 1) end
    local m, n = math.min(r, g, b) / mx, DC.theme_n
    return imgui.ImVec4(mx * (m + (1 - m) * n[1]), mx * (m + (1 - m) * n[2]),
                        mx * (m + (1 - m) * n[3]), a or 1)
end

function DC.theme_hex(r, g, b, k)
    local function c(v) return math.max(0, math.min(255, math.floor(v * k * 255 + 0.5))) end
    return string.format("%02X%02X%02X", c(r), c(g), c(b))
end

function DC.theme_apply(r, g, b)
    DC.theme[1], DC.theme[2], DC.theme[3] = r, g, b
    local mx = math.max(r, g, b, 0.001)
    DC.theme_n[1], DC.theme_n[2], DC.theme_n[3] = r / mx, g / mx, b / mx
    GREEN_BRIGHT = DC.theme_hex(r, g, b, 1.0)
    GREEN_MID    = DC.theme_hex(r, g, b, 0.88)
    GREEN_DARK   = DC.theme_hex(r, g, b, 0.65)

    local word, parts = "[EventScan]", {}
    for i = 1, #word do
        local t = (i - 1) / (#word - 1)
        parts[#parts + 1] = "{" .. DC.theme_hex(r, g, b, 1.0 - 0.35 * t) .. "}" .. word:sub(i, i)
    end
    DC.tag = table.concat(parts)
    DC.tag_color = tonumber(GREEN_BRIGHT, 16)
end

function DC.theme_save()
    local f = io.open(DC.THEME_FILE, "w")
    if not f then return false end
    f:write(DC.theme_hex(DC.theme[1], DC.theme[2], DC.theme[3], 1.0))
    f:close()
    return true
end

function DC.theme_load()
    local f = io.open(DC.THEME_FILE, "r")
    if not f then return end
    local hex = tostring(f:read("*a") or ""):match("%x%x%x%x%x%x")
    f:close()
    if not hex then return end
    DC.theme_apply(
        tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255)
end
DC.theme_apply(DC.THEME_DEFAULT[1], DC.THEME_DEFAULT[2], DC.THEME_DEFAULT[3])
DC.theme_load()

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
DC.espl_open_ref = espl_open
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
    avatar_file = DATA_DIR .. "espl_avatar.png",
    avatar_url   = nil,
    avatar_tex   = nil,
    avatar_ready = false,
    refreshing   = false,
}
local function cleanup_old_avatar_files()
    for name in DC.dir_iter(DATA_DIR) do
        if name:lower():match("^espl_avatar.*%.png$") then
            os.remove(DATA_DIR .. name)
        end
    end
end

local espl_top3 = {}

DC.tex_trash = {}
function DC.tex_discard()
    local tx = espl_panel.avatar_tex
    if tx then DC.tex_trash[#DC.tex_trash + 1] = { tex = tx, t = os.clock() } end
    espl_panel.avatar_tex = nil
end

function DC.tex_release()
    local now = os.clock()
    for i = #DC.tex_trash, 1, -1 do
        local e = DC.tex_trash[i]
        if now - e.t >= 1.0 then
            DC.trace("tex_release: releasing texture")
            if imgui.ReleaseTexture then pcall(imgui.ReleaseTexture, e.tex) end
            table.remove(DC.tex_trash, i)
        end
    end
end

function DC.image_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    if not d or #d < 24 then return nil end

    if d:sub(1, 4) == "\137PNG" then
        local b = { d:byte(17, 24) }
        return b[1] * 16777216 + b[2] * 65536 + b[3] * 256 + b[4],
               b[5] * 16777216 + b[6] * 65536 + b[7] * 256 + b[8]
    end

    if d:sub(1, 2) == "\255\216" then
        local pos, n = 3, #d
        while pos + 9 < n do
            if d:byte(pos) ~= 0xFF then
                pos = pos + 1
            else
                local m = d:byte(pos + 1)
                if m == 0xFF then
                    pos = pos + 1
                elseif m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
                    local h = d:byte(pos + 5) * 256 + d:byte(pos + 6)
                    local w = d:byte(pos + 7) * 256 + d:byte(pos + 8)
                    return w, h
                else
                    pos = pos + 2 + d:byte(pos + 2) * 256 + d:byte(pos + 3)
                end
            end
        end
    end
    return nil
end

function DC.cover_uv(path)
    local w, h = DC.image_size(path)
    if not w or not h or w <= 0 or h <= 0 or w == h then
        return DC.UV0, DC.UV1
    end
    if w > h then
        local m = (1 - h / w) / 2
        return imgui.ImVec2(m, 0), imgui.ImVec2(1 - m, 1)
    end
    local m = (1 - w / h) / 2
    return imgui.ImVec2(0, m), imgui.ImVec2(1, 1 - m)
end

function DC.avatar_fetch(hwid)
    if DC.avatar_busy and os.clock() - DC.avatar_busy < 40 then
        DC.trace("avatar_fetch: skipped, already running")
        return false, "busy"
    end
    DC.avatar_busy = os.clock()
    local ok, a, b = pcall(DC.avatar_fetch_inner, hwid)
    DC.avatar_busy = nil
    if not ok then
        DC.trace("avatar_fetch: ERROR " .. tostring(a))
        return false, tostring(a)
    end
    return a, b
end

function DC.avatar_fetch_inner(hwid)
    DC.trace("avatar_fetch: start")
    local final = DATA_DIR .. "espl_avatar.png"
    os.remove(final)

    local url = active_worker_url:gsub("/+$", "") .. "/avatar-proxy?hwid=" .. DC.url_encode(hwid)
    local ch = effil.channel()
    local ok_s, thr = pcall(DC.effil_start, DC.avatar_worker, ch, url, final)
    if not ok_s then return false, "thread_start_fail: " .. tostring(thr) end

    local r = wait_for_channel(ch, 25000, thr)
    if r == nil then pcall(function() thr:cancel(0) end) end
    DC.trace("avatar_fetch: worker done ok=" .. tostring(r and r.ok) .. " err=" .. tostring(r and r.err))
    if not (r and r.ok and DC.is_image_file(final)) then
        os.remove(final)
        return false, tostring(r and r.err or "timeout")
    end

    local iw, ih = DC.image_size(final)
    DC.trace("avatar_fetch: image size " .. tostring(iw) .. "x" .. tostring(ih))
    if not iw or not ih or iw < 1 or ih < 1 or iw > 4096 or ih > 4096 then
        os.remove(final)
        return false, "bad_image_size"
    end

    espl_panel.avatar_file  = final
    espl_panel.avatar_ready = true
    DC.tex_dirty = true
    return true
end

local function espl_format_balance(val)
    local s = string.format("%.0f", math.abs(tonumber(val) or 0))
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
            espl_local_author = DC.str(result.author) or espl_local_author
        end

        if result and result.ok and result.discord_linked then
            if not espl_panel.avatar_ready and not espl_panel.avatar_tex
                and (espl_panel.avatar_tries or 0) < 3 then
                espl_panel.avatar_tries = (espl_panel.avatar_tries or 0) + 1

                local ok_a, err_a = DC.avatar_fetch(hwid)
                if not ok_a then
                    DC.print("[EventScan] Не удалось подготовить аватарку: " .. tostring(err_a))
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

local function espl_refresh_avatar()
    if espl_panel.refreshing then return end

    local hwid = get_hwid()
    if not hwid then
        es_msg("HWID ещё не определён. Попробуй через пару секунд.", "FFAA00")
        return
    end

    espl_panel.refreshing = true

    DC.spawn(function()
        cleanup_old_avatar_files()
        espl_panel.avatar_url   = nil
        DC.tex_discard()
        espl_panel.avatar_ready = false
        espl_panel.avatar_tries = 0
        espl_panel.avatar_file  = DATA_DIR .. "espl_avatar.png"

        local ok_a, err_a = DC.avatar_fetch(hwid)
        if ok_a then
            es_msg("Аватарка обновлена!")
        else
            es_msg("Не удалось скачать аватарку: " .. tostring(err_a), "FFAA00")
        end

        espl_panel.refreshing = false
    end)
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
    local fail_streak = 0

    DC.spawn(function()
        while espl_open[0] and my_epoch == DC.esp_epoch and date_str == espl_selected_date do
            local hwid = get_hwid()
            if not hwid then
                wait(1000)
            else
                local t0 = os.clock()
                local channel = effil.channel()

                DC.trace("esp poll: starting wait thread, version=" .. tostring(version))
                local ok_s, thr = pcall(DC.effil_start, DC.esp_wait_worker,
                    channel, active_worker_url, hwid, date_str, version, DC.DEBUG and DC.LOG_FILE or "")

                local result
                if ok_s then

                    if my_epoch == DC.esp_epoch then
                        DC.esp_thread = thr
                    end
                    result = wait_for_channel(channel, 32000, thr)
                    DC.trace("esp poll: wait_for_channel returned " .. tostring(result and (result.ok and "ok" or result.err)))
                    if result == nil then pcall(function() thr:cancel(0) end) end
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
                    fail_streak = 0
                    DC.trace(string.format("esp poll: ok changed=%s slots=%s top3=%s stats=%s", tostring(result.changed), tostring(type(result.slots) == "table" and #result.slots or "nil"), tostring(type(result.top3) == "table" and #result.top3 or "nil"), tostring(result.stats ~= nil)))
                    version = result.version or version
                    if result.changed then
                        DC.espl_trace_left = 4
                        DC.trace("esp poll: applying changed result")
                        espl_loading    = false
                        espl_load_error = ""

                        local sched = {}
                        for _, s in ipairs(result.slots or {}) do
                            sched[s.time] = { author = DC.str(s.author) or "", title = DC.str(s.title) or "" }
                        end
                        espl_schedule = sched

                        if result.stats then
                            espl_panel.author  = DC.str(result.stats.author)
                            espl_panel.today   = DC.num(result.stats.reports_today)
                            espl_panel.week    = DC.num(result.stats.reports_week)
                            espl_panel.all      = DC.num(result.stats.reports_all)
                            espl_panel.balance  = DC.num(result.stats.balance)
                            espl_panel.loaded   = true
                            espl_panel.error    = ""
                        end

                        if result.top3 then
                            espl_top3 = DC.clean_top3(result.top3)
                        end
                    end
                    local spent_ms = (os.clock() - t0) * 1000
                    DC.trace(string.format("esp poll: sleeping %.0f ms", math.max(0, 1000 - spent_ms)))
                    if spent_ms < 1000 then wait(1000 - spent_ms) end
                    DC.trace("esp poll: next iteration")
                else
                    fail_streak = fail_streak + 1

                    if espl_loading then
                        espl_load_error = u8("Не удалось загрузить расписание: ")
                            .. tostring(result and result.err or "timeout")
                    end
                    wait(math.min(1000 * 2 ^ (fail_streak - 1), 15000))
                end
            end
        end
    end)
end

local function espl_select_date(ds)
    if ds == espl_selected_date then return end
    local now_t = os.clock()
    if now_t - (DC.sel_t or 0) < 1.0 then return end
    DC.sel_t = now_t
    espl_selected_date = ds
    espl_schedule       = {}
    espl_loading        = true
    espl_load_error      = ""
    DC.esp_start_polling(ds)
end

local ESPL_AMBER = "d4a24e"
local ESPL_ELLIPSIS = u8("…")

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
    local ov = DC.slot_override and DC.slot_override(author)
    if ov then return ov end
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

DC.SLOT_FILE  = DATA_DIR .. "slot_color.txt"
DC.slot_rgb   = nil
DC.slot_cache = nil
DC.slot_dirty = false

function DC.slot_auto_rgb()
    local key = (espl_local_author and espl_local_author ~= "") and espl_local_author or "—"
    return espl_hsl_to_rgb(espl_string_hash(key) % 360, 0.65, 0.52)
end

function DC.slot_override(author)
    if not DC.slot_rgb then return nil end
    if not espl_local_author or espl_local_author == "" or author ~= espl_local_author then return nil end
    if not DC.slot_cache then
        local r, g, b = DC.slot_rgb[1], DC.slot_rgb[2], DC.slot_rgb[3]
        DC.slot_cache = {
            border     = imgui.ImVec4(r, g, b, 1.0),
            border_dim = imgui.ImVec4(r, g, b, 0.5),
            bg         = imgui.ImVec4(r * 0.30, g * 0.30, b * 0.30, 1.0),
            bg_hover   = imgui.ImVec4(r * 0.45, g * 0.45, b * 0.45, 1.0),
            bg_dim     = imgui.ImVec4(r * 0.20, g * 0.20, b * 0.20, 0.7),
            accent     = imgui.ImVec4(math.min(r * 1.35, 1), math.min(g * 1.35, 1), math.min(b * 1.35, 1), 1.0),
        }
    end
    return DC.slot_cache
end

function DC.slot_set(r, g, b)
    DC.slot_rgb   = { r, g, b }
    DC.slot_cache = nil
end

function DC.slot_clear()
    DC.slot_rgb   = nil
    DC.slot_cache = nil
    os.remove(DC.SLOT_FILE)
end

function DC.slot_save()
    if not DC.slot_rgb then return end
    local f = io.open(DC.SLOT_FILE, "w")
    if not f then return end
    f:write(DC.theme_hex(DC.slot_rgb[1], DC.slot_rgb[2], DC.slot_rgb[3], 1.0))
    f:close()
end

function DC.slot_load()
    local f = io.open(DC.SLOT_FILE, "r")
    if not f then return end
    local hex = tostring(f:read("*a") or ""):match("%x%x%x%x%x%x")
    f:close()
    if not hex then return end
    DC.slot_set(tonumber(hex:sub(1, 2), 16) / 255,
                tonumber(hex:sub(3, 4), 16) / 255,
                tonumber(hex:sub(5, 6), 16) / 255)
end
DC.slot_load()

function DC.color_load_buf()
    if DC.color_mode == 2 then
        local r, g, b
        if DC.slot_rgb then
            r, g, b = DC.slot_rgb[1], DC.slot_rgb[2], DC.slot_rgb[3]
        else
            r, g, b = DC.slot_auto_rgb()
        end
        DC.color_buf[0], DC.color_buf[1], DC.color_buf[2] = r, g, b
    else
        DC.color_buf[0], DC.color_buf[1], DC.color_buf[2] = DC.theme[1], DC.theme[2], DC.theme[3]
    end
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

DC.click_seq   = 0
DC.click_last  = 0
DC.fstats      = {}
DC.slow_log_t  = {}

function DC.say(text)
    DC.trace("SEND chat: " .. tostring(text))
    local ok, err = pcall(sampSendChat, text)
    if not ok then
        DC.trace("SEND chat ERROR: " .. tostring(err))
        error(err, 0)
    end
end

function DC.dlg(id, button, item, text)
    DC.trace(string.format("SEND dialog response id=%s button=%s item=%s text=%s", tostring(id), tostring(button), tostring(item), DC.sum(text, 60)))
    local ok, err = pcall(sampSendDialogResponse, id, button, item, text)
    if not ok then
        DC.trace("SEND dialog response ERROR: " .. tostring(err))
        error(err, 0)
    end
end

function DC.sum(v, limit)
    limit = limit or 80
    local t = type(v)
    if t == "string" then
        if cached_hwid and v == cached_hwid then return "<HWID>" end
        if #v > limit then
            return string.format("<str len=%d head=%q>", #v, (v:sub(1, 24):gsub("[^\32-\126]", "?")))
        end
        return string.format("%q", (v:gsub("[^\32-\126\128-\255]", "?")))
    elseif t == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return "<table n=" .. n .. ">"
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(v)
    end
    return "<" .. t .. ">"
end

function DC.sumr(r)
    if type(r) ~= "table" then return tostring(r) end
    local items = {}
    for k, v in pairs(r) do items[#items + 1] = { tostring(k), v } end
    table.sort(items, function(a, b) return a[1] < b[1] end)
    local out = {}
    for _, it in ipairs(items) do out[#out + 1] = it[1] .. "=" .. DC.sum(it[2], 160) end
    return "{" .. table.concat(out, " ") .. "}"
end

function DC.click(kind, label, size)
    local mx, my = -1, -1
    pcall(function() local p = imgui.GetMousePos() mx, my = p.x, p.y end)
    local sx, sy = 0, 0
    pcall(function() if size then sx, sy = size.x, size.y end end)
    DC.click_seq = DC.click_seq + 1
    local now = os.clock()
    local gap = (now - DC.click_last) * 1000
    DC.click_last = now
    local visible = tostring(label):match("^(.-)##") or tostring(label)
    DC.trace(string.format("CLICK#%d %s label=%q visible=%q size=(%.0f,%.0f) mouse=(%.0f,%.0f) since_prev_click=%.0fms%s ctx{%s}",
        DC.click_seq, kind, tostring(label):gsub("\n", "\\n"), (visible:gsub("\n", "\\n")), sx, sy, mx, my, gap,
        gap < 150 and " RAPID" or "", DC.ctx()))
end

function DC.frame_stat(name, ms)
    local st = DC.fstats[name]
    if not st then st = { n = 0, total = 0, max = 0 } DC.fstats[name] = st end
    st.n = st.n + 1
    st.total = st.total + ms
    if ms > st.max then st.max = ms end
    if ms > 40 then
        local now = os.clock()
        if now - (DC.slow_log_t[name] or 0) > 1 then
            DC.slow_log_t[name] = now
            DC.trace(string.format("SLOW FRAME %s took %.1fms mem=%.0fKB ctx{%s}", name, ms, collectgarbage("count"), DC.ctx()))
        end
    end
end

pcall(function()
    local I = imgui
    I.__es_orig = I.__es_orig or {}
    local O = I.__es_orig
    for _, nm in ipairs({ "Button", "InputText", "ColorPicker3", "OnFrame" }) do
        if O[nm] == nil then O[nm] = I[nm] end
    end
    local oB, oI, oC, oF = O.Button, O.InputText, O.ColorPicker3, O.OnFrame

    I.Button = function(...)
        local label, size = ...
        local r = oB(...)
        if r then pcall(DC.click, "Button", label, size) end
        return r
    end

    I.InputText = function(...)
        local label, buf = ...
        local r = oI(...)
        if r then
            pcall(function()
                local txt = ffi.string(buf)
                DC.trace(string.format("INPUT %s changed len=%d text=%s", tostring(label), #txt, DC.sum(txt, 60)))
            end)
        end
        return r
    end

    I.ColorPicker3 = function(...)
        local label, buf = ...
        local r = oC(...)
        if r then
            local now = os.clock()
            if now - (DC.cp_t or 0) > 0.4 then
                DC.cp_t = now
                pcall(function()
                    DC.trace(string.format("COLORPICK %s rgb=(%.3f,%.3f,%.3f)", tostring(label), buf[0], buf[1], buf[2]))
                end)
            end
        end
        return r
    end

    I.OnFrame = function(cond, fn, ...)
        DC.frame_seq = (DC.frame_seq or 0) + 1
        local line = "?"
        pcall(function() line = tostring(debug.getinfo(fn, "S").linedefined) end)
        local name = string.format("frame#%d@%s", DC.frame_seq, line)
        DC.trace("OnFrame registered: " .. name)
        return oF(cond, function(...)
            local t0 = os.clock()
            local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end, ...)
            DC.frame_stat(name, (os.clock() - t0) * 1000)
            if not ok then
                DC.trace("FRAME ERROR " .. name .. ": " .. tostring(err))
                error(err, 0)
            end
        end, ...)
    end

    DC.restore_wrappers = function()
        for k, v in pairs(O) do I[k] = v end
    end
    DC.trace("imgui wrappers installed (Button, InputText, ColorPicker3, OnFrame)")
end)

imgui.OnFrame(function() return espl_open[0] end, function()
    DC.ftrace("begin")
    DC.espl_tick()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 8))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 16))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.055, 0.075, 0.055, 0.98))
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
                tab_bg     = DC.tc(0.09, 0.13, 0.09, 1.0)
                tab_border = hexcol(GREEN_MID, 0.45)
                tab_text   = DC.tc(0.78, 0.85, 0.78, 1.0)
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

    DC.ftrace("slots begin")
    DC.slots_cache = DC.slots_cache or espl_generate_time_slots()
    local slots     = DC.slots_cache
    local cols      = 8
    local slot_w    = 84
    local slot_h    = 44
    local label_max_w = slot_w - 16

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
            btn_bg       = DC.tc(0.10, 0.17, 0.10, 1.0)
            btn_bg_hover = DC.tc(0.16, 0.28, 0.16, 1.0)
            btn_border   = hexcol(GREEN_MID, 0.55)
            btn_text     = DC.tc(0.82, 0.92, 0.82, 1.0)
            border_size  = 1.0
        end

        imgui.PushStyleColor(imgui.Col.Button, btn_bg)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, btn_bg_hover)
        imgui.PushStyleColor(imgui.Col.ButtonActive, btn_bg_hover)
        imgui.PushStyleColor(imgui.Col.Border, btn_border)
        imgui.PushStyleColor(imgui.Col.Text, btn_text)
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, border_size)
        imgui.PushStyleVarVec2(imgui.StyleVar.ButtonTextAlign, imgui.ImVec2(0, 0.5))
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(8, 4))
        local slot_pos = imgui.GetCursorScreenPos()

        local label = time
        if is_booked then
            label = label .. "\n" .. espl_truncate_to_width(espl_short_nick(booking.author) or "", label_max_w)
        end

        local clicked = imgui.Button(label .. "##espl_slot_" .. time, imgui.ImVec2(slot_w, slot_h))

        do
            local key
            if is_booked then
                key = is_past and "slot_busy_past" or "slot_busy_live"
            elseif is_past then
                key = "slot_past"
            else
                key = grid_locked and "slot_free_off" or "slot_free_on"
            end

            local tex, uv0, uv1, _, col32 = DC.icon_params(key)
            if i == 1 or i == #slots then DC.ftrace("slot " .. i .. " key=" .. tostring(key) .. " booked=" .. tostring(is_booked) .. " past=" .. tostring(is_past) .. " tex=" .. tostring(tex)) end
            if tex then
                local spec = DC.ICON_SPEC[key]
                local bx1, by1 = slot_pos.x + slot_w, slot_pos.y + slot_h
                local ix = math.floor(bx1 - spec.size + 8 + 0.5)
                local iy = math.floor(by1 - spec.size + 6 + 0.5)

                imgui.GetWindowDrawList():AddImage(
                    tex,
                    imgui.ImVec2(ix, iy), imgui.ImVec2(ix + spec.w, iy + spec.h),
                    uv0, uv1, col32)
            end
        end

        imgui.PopStyleVar(3)
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

    DC.ftrace("slots done")
    local main_win_pos  = imgui.GetWindowPos()
    local main_win_size = imgui.GetWindowSize()

    imgui.End()
    DC.ftrace("main window done")

    local SIDE_GAP = 8
    imgui.SetNextWindowPos(
        imgui.ImVec2(main_win_pos.x + main_win_size.x + SIDE_GAP, main_win_pos.y),
        imgui.Cond.Always
    )

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 6))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 14))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.055, 0.075, 0.055, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))

    imgui.Begin('##espl_side_panel', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoMove)

    DC.ftrace("side panel")
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

    if espl_panel.avatar_tex then

        DC.ftrace("avatar draw tex=" .. tostring(espl_panel.avatar_tex))
        draw_list:AddImageRounded(
            espl_panel.avatar_tex,
            avatar_pos, avatar_p2,
            espl_panel.avatar_uv0 or DC.UV0, espl_panel.avatar_uv1 or DC.UV1,
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
        center_text(u8("Загрузка..."), hexcol(GREEN_BRIGHT, 0.7))
    elseif espl_panel.error ~= "" then
        center_text(u8("Ошибка"), imgui.ImVec4(1, 0.35, 0.35, 1))
    else

        local nick_display = espl_panel.author or espl_local_author or "—"
        center_text(nick_display, hexcol(GREEN_BRIGHT))

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
        imgui.Separator()
        imgui.PopStyleColor(1)
        imgui.Spacing()

        local bal_str = espl_format_balance(espl_panel.balance)
        DC.ftrace("stats balance=" .. tostring(espl_panel.balance) .. " today=" .. tostring(espl_panel.today) .. " author=" .. tostring(espl_panel.author))
        local bal_color = espl_panel.balance >= 0
            and hexcol(GREEN_BRIGHT)
            or imgui.ImVec4(1, 0.35, 0.35, 1)
        do
            local isz  = imgui.GetTextLineHeight()
            local ig   = 2
            local has  = DC.icon_get("coin") ~= nil
            local tw   = imgui.CalcTextSize(bal_str).x + (has and (isz + ig) or 0)
            local avail = imgui.GetContentRegionAvail().x
            if tw < avail then
                imgui.SetCursorPosX(math.floor(imgui.GetCursorPosX() + (avail - tw) / 2 + 0.5))
            end
            if has then
                DC.icon_draw("coin", isz)
                imgui.SameLine(0, ig)
            end
            imgui.TextColored(bal_color, bal_str)
        end

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
        imgui.Separator()
        imgui.PopStyleColor(1)
        imgui.Spacing()

        local label_color = DC.tc(0.65, 0.75, 0.65, 1)
        local value_color = imgui.ImVec4(1, 1, 1, 1)

        imgui.TextColored(label_color, u8("Сегодня:"))
        imgui.SameLine(SIDE_W - imgui.CalcTextSize(tostring(espl_panel.today)).x)
        imgui.TextColored(value_color, tostring(espl_panel.today))

        imgui.TextColored(label_color, u8("За неделю:"))
        imgui.SameLine(SIDE_W - imgui.CalcTextSize(tostring(espl_panel.week)).x)
        imgui.TextColored(value_color, tostring(espl_panel.week))

        imgui.TextColored(label_color, u8("Всего:"))
        imgui.SameLine(SIDE_W - imgui.CalcTextSize(tostring(espl_panel.all)).x)
        imgui.TextColored(value_color, tostring(espl_panel.all))

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
        imgui.Separator()
        imgui.PopStyleColor(1)
        imgui.Spacing()

        if espl_panel.refreshing then
            center_text(u8("Обновление..."), hexcol(GREEN_BRIGHT, 0.7))
        else
            local sq  = 26
            local gap = imgui.GetStyle().ItemSpacing.x
            if imgui.Button(u8("Обновить аватарку"), imgui.ImVec2(SIDE_W - sq - gap, sq)) then
                espl_refresh_avatar()
            end
            imgui.SameLine(0, gap)
            if imgui.Button("##es_color_btn", imgui.ImVec2(sq, sq)) then
                DC.color_open = not DC.color_open
                if DC.color_open then
                    DC.color_mode = 1
                    DC.color_load_buf()
                    DC.color_focus = true
                end
            end
            do
                local bmin, bmax = imgui.GetItemRectMin(), imgui.GetItemRectMax()
                local cx, cy = (bmin.x + bmax.x) / 2, (bmin.y + bmax.y) / 2
                local dl  = imgui.GetWindowDrawList()
                local tex = DC.icon_get("color")
                if tex then
                    local half = DC.ICON_SPEC.color.w / 2
                    dl:AddImage(tex, imgui.ImVec2(cx - half, cy - half), imgui.ImVec2(cx + half, cy + half))
                else
                    dl:AddRectFilled(imgui.ImVec2(cx - 6, cy - 6), imgui.ImVec2(cx + 6, cy + 6),
                        imgui.ColorConvertFloat4ToU32(hexcol(GREEN_BRIGHT)), 3)
                end
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

    DC.ftrace("top3")
    local top3_content_w = imgui.GetContentRegionAvail().x

    center_text(u8("Топ за неделю"), hexcol(GREEN_BRIGHT))
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Separator, hexcol(GREEN_MID, 0.3))
    imgui.Separator()
    imgui.PopStyleColor(1)
    imgui.Spacing()

    if #espl_top3 == 0 then
        center_text(u8("Пока нет отчётов"), imgui.ImVec4(0.6, 0.6, 0.6, 1))
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

            local nick       = espl_short_nick(entry.author) or entry.author or "—"
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
    DC.ftrace("end")
    if (DC.espl_trace_left or 0) > 0 then DC.espl_trace_left = DC.espl_trace_left - 1 end
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
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.05, 0.08, 0.05, 0.98))
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

DC.color_open  = false
DC.color_focus = false
DC.color_mode  = 1
DC.color_buf   = imgui.new.float[3](DC.theme[1], DC.theme[2], DC.theme[3])

DC.color_frame = imgui.OnFrame(function() return DC.color_open and espl_open[0] end, function()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 12))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 8))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.05, 0.08, 0.05, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(GREEN_BRIGHT))

    local io = imgui.GetIO()
    imgui.SetNextWindowPos(
        imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2),
        imgui.Cond.Appearing, imgui.ImVec2(0.5, 0.5))
    if DC.color_focus then
        imgui.SetNextWindowFocus()
        DC.color_focus = false
    end

    imgui.Begin('##es_color_window', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.AlwaysAutoResize)

    local W = 200
    center_text(DC.color_mode == 2 and u8("Цвет моих полей") or u8("Основной цвет"), hexcol(GREEN_BRIGHT))

    do
        local tab_gap = 6
        local tab_w   = (W - tab_gap) / 2
        local labels  = { u8("Основной"), u8("Мои поля") }
        for i = 1, 2 do
            local active = DC.color_mode == i
            imgui.PushStyleColor(imgui.Col.Button, active and hexcol(GREEN_MID) or DC.tc(0.18, 0.22, 0.18, 1))
            if imgui.Button(labels[i] .. "##es_cmode" .. i, imgui.ImVec2(tab_w, 26)) and not active then
                if DC.slot_dirty then DC.slot_dirty = false DC.slot_save() end
                DC.color_mode = i
                DC.color_load_buf()
            end
            imgui.PopStyleColor(1)
            if i == 1 then imgui.SameLine(0, tab_gap) end
        end
    end

    local flags = (imgui.ColorEditFlags.PickerHueWheel or 0)
        + (imgui.ColorEditFlags.NoSidePreview or 0)
        + (imgui.ColorEditFlags.NoInputs or 0)
    imgui.PushItemWidth(W)
    if imgui.ColorPicker3('##es_color_pick' .. DC.color_mode, DC.color_buf, flags) then
        if DC.color_mode == 2 then
            DC.slot_set(DC.color_buf[0], DC.color_buf[1], DC.color_buf[2])
            DC.slot_dirty = true
        else
            DC.theme_apply(DC.color_buf[0], DC.color_buf[1], DC.color_buf[2])
            DC.theme_dirty = true
        end
    end
    imgui.PopItemWidth()

    if DC.theme_dirty and not imgui.IsMouseDown(0) then
        DC.theme_dirty = false
        DC.theme_save()
    end
    if DC.slot_dirty and not imgui.IsMouseDown(0) then
        DC.slot_dirty = false
        DC.slot_save()
    end

    local gap = 8
    local bw  = (W - gap) / 2

    local avail = imgui.GetContentRegionAvail().x
    bw = (avail - gap) / 2
    if imgui.Button(u8("Сбросить"), imgui.ImVec2(bw, 28)) then
        if DC.color_mode == 2 then
            DC.slot_clear()
            DC.slot_dirty = false
            DC.color_load_buf()
        else
            local d = DC.THEME_DEFAULT
            DC.color_buf[0], DC.color_buf[1], DC.color_buf[2] = d[1], d[2], d[3]
            DC.theme_apply(d[1], d[2], d[3])
            DC.theme_save()
        end
    end
    imgui.SameLine(0, gap)
    if imgui.Button(u8("Готово"), imgui.ImVec2(bw, 28)) then
        DC.theme_save()
        if DC.slot_dirty then DC.slot_dirty = false DC.slot_save() end
        DC.color_open = false
    end

    imgui.End()

    imgui.PopStyleColor(6)
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

    DC.trace('toast: ' .. tostring(text))
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

    DC.trace('ess toast: ' .. tostring(text))
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

function DC.ctx()
    local ok, res = pcall(function()
        local chat, dlg = false, false
        pcall(function() chat = sampIsChatInputActive() dlg = sampIsDialogActive() end)
        return string.format(
            "esp=%s modal=%s color=%s tp=%s cursor=%s winner=%s scanprompt=%s screens=%s bank=%s chat=%s dialog=%s inflight=%d eth=%d lth=%d scans=%d players=%d mem=%.0fKB egc=%s",
            tostring(espl_open[0]), tostring(espl_modal_open), tostring(DC.color_open),
            tostring(DC.tp_timer and DC.tp_timer.visible), tostring(DC.cursor_unlocked),
            tostring(DC.winner and DC.winner.open),
            tostring(DC.scan_prompt and DC.scan_prompt.open), tostring(screens_path_open[0]),
            tostring(DC.bank and DC.bank.state), tostring(chat), tostring(dlg),
            DC.inflight, #DC.ethreads, #DC.lthreads, #pending_scans, #unique_players_order,
            collectgarbage("count"), DC.egc_info())
    end)
    return ok and res or ("ctx_error:" .. tostring(res))
end

function DC.state_snapshot()
    local s = {}
    s.esp_open      = espl_open[0]
    s.esp_date      = tostring(espl_selected_date)
    s.esp_loading   = espl_loading
    s.esp_error     = espl_load_error ~= "" and espl_load_error or false
    s.modal         = espl_modal_open and (tostring(espl_modal_mode) .. "@" .. tostring(espl_modal_time)) or false
    s.modal_busy    = espl_modal_busy
    s.color_open    = DC.color_open
    s.color_mode    = DC.color_mode
    s.tp_visible    = DC.tp_timer.visible
    s.cursor_unlock = DC.cursor_unlocked
    s.rebinding     = DC.rebinding
    s.winner_open   = DC.winner.open
    s.scan_prompt   = DC.scan_prompt.open
    s.screens_dlg   = screens_path_open[0]
    s.toast         = toast_visible[0]
    s.ess_toast     = ess_toast_visible[0]
    s.alerts        = #DC.alerts
    s.bank          = tostring(DC.bank.state)
    s.scanning      = scanning_active and true or false
    s.auth_win      = DC.win_open[0]
    s.linked        = DC.linked
    s.avatar_tex    = espl_panel.avatar_tex ~= nil
    s.stats_loading = espl_panel.loading
    s.hwid_known    = cached_hwid ~= nil
    s.worker_url    = active_worker_url
    s.scans         = #pending_scans
    s.players       = #unique_players_order
    pcall(function()
        s.chat_input = sampIsChatInputActive() and true or false
        s.dialog     = sampIsDialogActive() and true or false
    end)
    return s
end

function DC.state_watch_start()
    DC.spawn(function()
        local prev, last_dump = nil, os.clock()
        while true do
            wait(100)
            local ok, snap = pcall(DC.state_snapshot)
            if ok then
                if not prev then
                    local ks = {}
                    for k in pairs(snap) do ks[#ks + 1] = k end
                    table.sort(ks)
                    local parts = {}
                    for _, k in ipairs(ks) do parts[#parts + 1] = k .. "=" .. tostring(snap[k]) end
                    DC.trace("STATE init: " .. table.concat(parts, " "))
                else
                    for k, v in pairs(snap) do
                        if prev[k] ~= v then
                            DC.trace(string.format("STATE %s: %s -> %s", k, tostring(prev[k]), tostring(v)))
                        end
                    end
                end
                prev = snap
            else
                DC.trace("STATE snapshot error: " .. tostring(snap))
            end

            if os.clock() - last_dump >= 30 then
                last_dump = os.clock()
                local names = {}
                for nm in pairs(DC.fstats) do names[#names + 1] = nm end
                table.sort(names)
                for _, nm in ipairs(names) do
                    local st = DC.fstats[nm]
                    if st.n > 0 then
                        DC.trace(string.format("FRAMESTAT %s frames=%d avg=%.2fms max=%.2fms (last 30s)", nm, st.n, st.total / st.n, st.max))
                    end
                    st.n, st.total, st.max = 0, 0, 0
                end
            end
        end
    end)
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
        imgui.ColorConvertFloat4ToU32(DC.tc(0.06, 0.09, 0.06, alpha)),
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
    do
        if toast_font then imgui.PushFont(toast_font) end
        local tw = imgui.CalcTextSize(ess_toast_state.text).x
        if toast_font then imgui.PopFont() end
        win_w = math.max(200, tw + TOAST_PAD * 2 + 24)
    end
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
        imgui.ColorConvertFloat4ToU32(DC.tc(0.06, 0.09, 0.06, alpha)),
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

    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.06, 0.09, 0.06, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.TitleBg, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.FrameBg, DC.tc(0.10, 0.14, 0.10, 1))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, DC.tc(0.12, 0.20, 0.12, 1))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, DC.tc(0.14, 0.24, 0.14, 1))
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
                local browse_thr = DC.effil_start(browse_folder_worker,
                    browse_channel, u8('Выберите папку arizona\\screens')
                )

                local browse_result = wait_for_channel(browse_channel, 120000, browse_thr)

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
    for file_name in DC.dir_iter(root_folder) do
        if file_name ~= "." and file_name ~= ".." then
            local full_sub_path = root_folder .. "\\" .. file_name
            if is_dir(full_sub_path) then
                local ok_a, attr = pcall(lfs.attributes, full_sub_path)
                if ok_a and attr and attr.modification > max_folder_time then
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
        local ln = file_name:lower()
        if ln:sub(-4) == ".jpg" or ln:sub(-4) == ".png" or ln:sub(-5) == ".jpeg" then
            local full_file_path = latest_subfolder .. "\\" .. file_name
            local ok_a, attr = pcall(lfs.attributes, full_file_path)
            if ok_a and attr and attr.mode == "file" and attr.modification > max_file_time then
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
        local ok_a, attr = pcall(lfs.attributes, path)
        local size = (ok_a and attr) and attr.size or nil

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

    DC.spawn(function()
        DC.trace('capture: start')
        local _, baseline_err, baseline_time = find_latest_screenshot_in(root_folder)
        DC.trace('capture: baseline ok')
        baseline_time = baseline_time or 0

        DC.trace('capture: chatlog lookup')
        local chatlog_path = get_cached_chatlog_path()
        DC.trace('capture: chatlog=' .. tostring(chatlog_path))
        local chatlog_baseline_size = nil
        if chatlog_path then
            local ok_a, attr = pcall(lfs.attributes, chatlog_path)
            chatlog_baseline_size = (ok_a and attr) and attr.size or 0
        end

        DC.trace('capture: pressing F8')
        setVirtualKeyDown(vkeys.VK_F8, true)
        wait(50)
        setVirtualKeyDown(vkeys.VK_F8, false)
        DC.trace('capture: F8 released')

        local target_file
        local chat_notice_shown = false
        local waited = 0
        while waited < SCREENSHOT_MAX_WAIT do
            wait(SCREENSHOT_POLL_INTERVAL)
            waited = waited + SCREENSHOT_POLL_INTERVAL

            if not chat_notice_shown and chatlog_path and chatlog_baseline_size then
                local ok_a, attr = pcall(lfs.attributes, chatlog_path)
                local size = (ok_a and attr) and attr.size or 0
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

        DC.trace('capture: file found ' .. tostring(target_file))
        wait_until_file_stable(target_file)
        DC.trace('capture: file stable')

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

        DC.trace('capture: file read, bytes=' .. tostring(#binary_data) .. ', uploading')
        show_toast(u8("Сканирую..."), GREEN_BRIGHT)

        local hwid_value = get_hwid()
        local result = try_worker_urls(screenshot_upload_worker, function(url)
            return { binary_data, hwid_value, DC.DEBUG and DC.LOG_FILE or "" }
        end, 20000)
        DC.trace('capture: upload result ok=' .. tostring(result and result.ok) .. ' err=' .. tostring(result and result.err))
        if result and result.ok then
            show_toast(u8("Готово!"), GREEN_BRIGHT)
            wait(2000)
            hide_toast()
            DC.trace('capture: callback')
            callback(result.url)
        else
            local err = result and result.err or "timeout"
            if is_hwid_error(err) then
                copy_to_clipboard(get_hwid() or "UNKNOWN")
                show_toast(u8("Hwid"), "FF4444")
                wait(2000)
                hide_toast()
                callback(nil)
            else
                show_toast(u8("Сохранено"), "FFAA00")
                wait(2000)
                hide_toast()
                callback(nil, target_file)
            end
        end
    end)
end

local function fetch_last_report_from_d1(on_done)
    DC.spawn(function()
        local result = try_worker_urls(d1_last_report_worker, function(url)
            return {}
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

    DC.spawn(function()
        local channel = effil.channel()
        local thr = DC.effil_start(update_download_worker, channel, UPDATE_DOWNLOAD_URL)

        local result = wait_for_channel(channel, 30000, thr)
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
    DC.spawn(function()
        local channel = effil.channel()
        local thr = DC.effil_start(version_check_worker, channel, VERSION_CHECK_URL)

        local result = wait_for_channel(channel, 15000, thr)
        DC.trace('update check: ok=' .. tostring(result and result.ok) .. ' remote=' .. tostring(result and result.version) .. ' local=' .. tostring(SCRIPT_VERSION))
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

DC.win_open = imgui_new.bool(false)

DC.net_open = imgui_new.bool(false)
DC.net_frame = imgui.OnFrame(function() return DC.net_open[0] end, function()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 12))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.055, 0.075, 0.055, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.TitleBg, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(GREEN_BRIGHT))
    imgui.PushStyleColor(imgui.Col.Header, DC.tc(0.10, 0.17, 0.10, 1))
    imgui.PushStyleColor(imgui.Col.HeaderHovered, DC.tc(0.16, 0.28, 0.16, 1))
    imgui.PushStyleColor(imgui.Col.HeaderActive, DC.tc(0.20, 0.34, 0.20, 1))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))

    local io = imgui.GetIO()
    imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2),
        imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(660, 430), imgui.Cond.FirstUseEver)
    imgui.Begin(u8("Сеть EventScan") .. "##es_net_window", DC.net_open,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoSavedSettings)

    local label_color = DC.tc(0.65, 0.75, 0.65, 1)
    imgui.TextColored(label_color, u8("Запросов за сессию: ") .. #DC.net.log)
    imgui.SameLine(0, 16)
    if imgui.Button(u8("Очистить") .. "##es_net_clear", imgui.ImVec2(90, 24)) then
        DC.net.log = {}
    end
    imgui.Separator()

    imgui.BeginChild("##es_net_list", imgui.ImVec2(0, 0), false)
    local log = DC.net.log
    local function row(label, value)
        imgui.TextColored(label_color, label)
        imgui.SameLine(0, 6)
        imgui.TextWrapped(tostring(value))
    end
    for i = #log, 1, -1 do
        local e = log[i]
        local col = e.status == "OK" and hexcol(GREEN_BRIGHT) or imgui.ImVec4(1, 0.35, 0.35, 1)
        imgui.PushStyleColor(imgui.Col.Text, col)
        local open = imgui.CollapsingHeader(string.format("%s -- %s  %d ms##es_net_%d", e.name, e.status, math.floor(e.ms), e.id))
        imgui.PopStyleColor(1)
        if open then
            imgui.PushTextWrapPos(0)
            row(u8("Время:"), e.time)
            row(u8("Воркер:"), e.url)
            row(u8("Попытка:"), e.tag)
            row(u8("Пинг:"), string.format("%.0f ms (", e.ms) .. u8("лимит ") .. string.format("%d ms)", e.tmo))
            row(u8("Запрос:"), e.name .. "(" .. e.args .. ")")
            row(u8("Ответ:"), e.result)
            imgui.PopTextWrapPos()
            imgui.Spacing()
        end
    end
    imgui.EndChild()

    imgui.End()
    imgui.PopStyleColor(11)
    imgui.PopStyleVar(3)
end)

function DC.url_encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

function DC.open_browser()
    local hwid = get_hwid()
    if not hwid then
        es_msg("HWID ещё не определён. Попробуй через пару секунд.", "FFAA00")
        return
    end

    DC.spawn(function()
        local gen_result = try_worker_urls(gen_token_worker, function(url)
            return { hwid, "discord" }
        end, 15000)

        if not gen_result or not gen_result.ok or not gen_result.token then
            local err = gen_result and gen_result.err or "timeout"
            if is_hwid_error(err) then
                notify_hwid_denied()
            else
                es_msg("Не удалось подготовить ссылку авторизации: " .. tostring(err), "FF4444")
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
            es_msg("Не удалось открыть браузер. Ссылка скопирована в буфер обмена — вставь её в браузер.", "FF4444")
        else
            es_msg("Открываю страницу авторизации Discord в браузере...")
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
                es_msg("Discord успешно привязан! Можешь пользоваться командами.")

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
        es_msg("HWID ещё не определён. Попробуй через пару секунд.", "FFAA00")
        return
    end

    DC.checking = true
    DC.spawn(function()
        local r = DC.fetch_status()
        DC.checking = false
        DC.trace('auth check: ok=' .. tostring(r and r.ok) .. ' allowed=' .. tostring(r and r.allowed) .. ' linked=' .. tostring(r and r.discord_linked) .. ' err=' .. tostring(r and r.err))

        if not (r and r.ok) then
            es_msg("Не удалось проверить авторизацию: " .. tostring(r and r.err or "timeout"), "FF4444")
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
        DC.trace("command: /" .. tostring(name) .. " params=" .. tostring(params))
        DC.require(function()
            local ok, err = pcall(handler, params)
            if not ok then
                DC.trace("COMMAND ERROR /" .. tostring(name) .. ": " .. tostring(err))
                DC.print("[EventScan] Ошибка в команде /" .. tostring(name) .. ": " .. tostring(err))
            end
        end)
    end)
end

imgui.OnFrame(function() return DC.win_open[0] end, function()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(18, 16))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 10))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.055, 0.075, 0.055, 0.98))
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

    center_text(u8("Требуется авторизация"), hexcol(GREEN_BRIGHT))
    imgui.Spacing()
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + W)
    imgui.TextWrapped(u8("Чтобы пользоваться EventScan, привяжи свой Discord-аккаунт. Нажми кнопку ниже, авторизуйся в браузере и вернись в игру — окно закроется само."))
    imgui.PopTextWrapPos()
    imgui.Spacing()

    if imgui.Button(u8("Авторизоваться через Discord"), imgui.ImVec2(W, 34)) then
        DC.open_browser()
    end

    if DC.polling then
        center_text(u8("Жду подтверждения..."), DC.tc(0.65, 0.75, 0.65, 1))
    end

    if imgui.Button(u8("Закрыть"), imgui.ImVec2(W, 28)) then
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

DC.tp_timer = {
    visible   = false,
    end_epoch = 0,
    total     = 0,
    opened_at = 0,
}

DC.people_now      = 0
DC.people_max      = 0
DC.cursor_unlocked = false
DC.tp_frame        = nil

DC.cursor_key = vkeys.VK_X
DC.rebinding  = false
DC.KEY_FILE   = DATA_DIR .. "tp_key.txt"

function DC.key_save()
    local f = io.open(DC.KEY_FILE, "w")
    if not f then return end
    f:write(tostring(DC.cursor_key))
    f:close()
end

function DC.key_load()
    local f = io.open(DC.KEY_FILE, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local vk = tonumber(tostring(content or ""):match("%d+"))
    if vk and vk >= 8 and vk <= 254 then DC.cursor_key = vk end
end

DC.POS_FILE     = DATA_DIR .. "tp_pos.txt"
DC.tp_pos       = nil
DC.tp_last_pos  = nil
DC.tp_default   = nil

function DC.pos_load()
    local f = io.open(DC.POS_FILE, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local x, y = tostring(content or ""):match("(-?[%d%.]+)%s+(-?[%d%.]+)")
    x, y = tonumber(x), tonumber(y)
    if x and y then DC.tp_pos = { x = x, y = y } end
end

function DC.pos_save_if_moved()
    local cur = DC.tp_last_pos
    if not cur then return end
    local old = DC.tp_pos or DC.tp_default
    if old and math.abs(old.x - cur.x) < 0.5 and math.abs(old.y - cur.y) < 0.5 then return end
    DC.tp_pos = { x = cur.x, y = cur.y }
    local f = io.open(DC.POS_FILE, "w")
    if not f then return end
    f:write(string.format("%.1f %.1f", cur.x, cur.y))
    f:close()
end

function DC.key_name()
    local ok, name = pcall(vkeys.id_to_name, DC.cursor_key)
    if ok and name and name ~= "" then return name end
    return "VK" .. tostring(DC.cursor_key)
end

function DC.tp_set_cursor(state)
    DC.trace('cursor unlocked=' .. tostring(state))
    if DC.cursor_unlocked and not state then DC.pos_save_if_moved() end
    DC.cursor_unlocked = state
    if DC.tp_frame then
        DC.tp_frame.HideCursor = not state
        DC.tp_frame.LockPlayer = state
    end
end

function DC.tp_set_visible(v)
    DC.trace('tp_set_visible ' .. tostring(v))
    if v and not DC.tp_timer.visible then
        DC.tp_timer.opened_at = os.time()
        DC.people_max = #unique_players_order
        DC.people_now = 0
    end
    DC.tp_timer.visible = v
    if not v then
        DC.rebinding = false
        DC.tp_set_cursor(false)
        pcall(DC.alert_clear)
        pcall(DC.winner_close)
        pcall(DC.scan_prompt_close)
    end
end

function DC.duration_format(sec)
    sec = math.max(0, sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

function DC.send_cmd(cmd)
    DC.spawn(function() wait(0) DC.say(cmd) end)
end

function DC.cursor_start_loop()
    DC.spawn(function()
        while true do
            wait(0)
            if DC.tp_timer.visible then
                if DC.rebinding then
                    if wasKeyPressed(DC.cursor_key) then
                        DC.rebinding = false
                    else
                        for vk = 8, 254 do
                            if wasKeyPressed(vk) then
                                DC.cursor_key = vk
                                DC.key_save()
                                DC.rebinding = false
                                break
                            end
                        end
                    end
                elseif wasKeyPressed(DC.cursor_key)
                    and not DC.winner.open
                    and not sampIsChatInputActive()
                    and not sampIsDialogActive() then
                    DC.tp_set_cursor(not DC.cursor_unlocked)
                end
            end
        end
    end)
end

DC.TP_FILE = DATA_DIR .. "tp_last.txt"

function DC.tp_save()
    local f = io.open(DC.TP_FILE, "w")
    if not f then return end
    f:write(string.format("%d %d", DC.tp_timer.end_epoch, DC.tp_timer.total))
    f:close()
end

function DC.tp_load()
    local f = io.open(DC.TP_FILE, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local e, t = tostring(content or ""):match("(%d+)%s+(%d+)")
    if e and t then
        DC.tp_timer.end_epoch = tonumber(e)
        DC.tp_timer.total     = tonumber(t)
    end
end

DC.AUTO_FILE = DATA_DIR .. "auto_mode.txt"
DC.auto_mode = true

function DC.auto_save()
    local f = io.open(DC.AUTO_FILE, "w")
    if not f then return end
    f:write(DC.auto_mode and "1" or "0")
    f:close()
end

function DC.auto_load()
    local f = io.open(DC.AUTO_FILE, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local v = tostring(content or "")
    if v:find("[01]") then DC.auto_mode = v:find("1", 1, true) ~= nil end
end

function DC.tp_timer_format(remaining)
    if DC.tp_timer.total >= 60 then
        return string.format("%02d:%02d", math.floor(remaining / 60), remaining % 60)
    end
    return string.format("%02d", remaining)
end

DC.TP_KEYWORD = "запустил мероприятие"

function DC.tp_has_keyword(clean)
    if clean:find(DC.TP_KEYWORD, 1, true) then return true end
    local ok, dec = pcall(function() return u8:decode(DC.TP_KEYWORD) end)
    if ok and dec and clean:find(dec, 1, true) then return true end
    return false
end

DC.TP_OFF_TEXT = "выключил телепорт на мероприятие"

function DC.tp_off_match(clean)
    local function esc(str)
        return (str:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
    end

    local variants = { DC.TP_OFF_TEXT }
    local ok, dec = pcall(function() return u8:decode(DC.TP_OFF_TEXT) end)
    if ok and dec and dec ~= DC.TP_OFF_TEXT then variants[#variants + 1] = dec end

    for _, v in ipairs(variants) do
        local pat = "^%s*%[Game Event%]%s+A:%s+(%S+)%s+" .. esc(v) .. "%s*%.?%s*$"
        local nick = clean:match(pat)
        if nick then return nick end
    end
    return nil
end

function DC.tp_handle_off(clean)
    if not DC.tp_timer.visible then return end
    if not clean:find("[Game Event]", 1, true) then return end

    local who = DC.tp_off_match(clean)
    if not who then return end

    if DC.tp_timer.end_epoch > os.time() then
        DC.tp_timer.end_epoch = os.time()
        DC.tp_save()
        DC.print("[EventScan] Телепорт выключен (" .. tostring(who) .. "), таймер остановлен досрочно.")

    end
end

function DC.sampev_onServerMessage(color, text)
    if type(text) ~= "string" then return end

    local clean = text:gsub("{%x%x%x%x%x%x}", "")

    if clean:find("[Game Event]", 1, true) or clean:find("[A]", 1, true) then
        DC.trace("CHAT-IN: " .. clean:sub(1, 200))
    end
    pcall(DC.give_register, clean)
    pcall(DC.bank_on_message, clean)
    local ok_off, err_off = pcall(DC.tp_handle_off, clean)
    if not ok_off then DC.print("[EventScan] Ошибка в tp_handle_off: " .. tostring(err_off)) end

    if not clean:find("[Game Event]", 1, true) then return end
    if not DC.tp_has_keyword(clean) then return end

    local nick = clean:match("A:%s*(%S+)")
    local secs = clean:match(".*:%s*(%d+)")
    if not nick or not secs then return end

    if nick:lower() ~= get_local_nickname():lower() then return end

    if not DC.auto_mode then
        DC.trace('event started by me, but auto mode (/-ehelper) is off: window not opened')
        return
    end

    secs = tonumber(secs)
    if not secs then return end
    DC.trace('event started by me: seconds=' .. tostring(secs))

    DC.tp_timer.total     = secs
    DC.tp_timer.end_epoch = os.time() + secs
    DC.tp_set_visible(true)
    DC.tp_save()
    DC.tp_armed = true
end

DC.ICON_DIR  = DATA_DIR .. "icons\\"

DC.ICON_BASE_URL = "https://raw.githubusercontent.com/SaportBati/eventCRM/refs/heads/main/icons/"
DC.ICON_REV      = "r1"

DC.ICON_VARIANTS = {
    { key = "hourglass_green", size = 27, w = 27, h = 27 },
    { key = "hourglass_red",   size = 27, w = 27, h = 27 },
    { key = "stopwatch",       size = 27, w = 27, h = 27 },
    { key = "person",          size = 16, w = 16, h = 16 },
    { key = "people",          size = 16, w = 16, h = 16 },
    { key = "coin",            size = 16, w = 16, h = 16 },
    { key = "slot_free_on",    size = 32, w = 21, h = 23 },
    { key = "slot_free_off",   size = 32, w = 21, h = 23 },
    { key = "slot_busy_live",  size = 32, w = 21, h = 23 },
    { key = "slot_busy_past",  size = 32, w = 21, h = 23 },
    { key = "slot_past",       size = 32, w = 21, h = 23 },
    { key = "color",           size = 18, w = 18, h = 18, file = "color" },
}

DC.ICON_SPEC = {}

function DC.icon_specs_init()
    for _, v in ipairs(DC.ICON_VARIANTS) do
        DC.ICON_SPEC[v.key] = v
    end
end
DC.icon_specs_init()

DC.icon_ready  = {}
DC.icon_tex    = {}
DC.icon_failed = {}
DC.tex_dirty   = false

DC.UV0 = imgui.ImVec2(0, 0)
DC.UV1 = imgui.ImVec2(1, 1)
DC.WHITE4 = imgui.ImVec4(1, 1, 1, 1)

function DC.icon_name(key)
    local v = DC.ICON_SPEC[key]
    if v and v.file then return v.file .. ".png" end
    return key .. "_" .. DC.ICON_REV .. ".png"
end

function DC.icon_path(key)
    return DC.ICON_DIR .. DC.icon_name(key)
end

function DC.icon_prepare(key)
    local path = DC.icon_path(key)
    if not DC.is_image_file(path) then
        local url = DC.ICON_BASE_URL .. DC.icon_name(key)
        local ch = effil.channel()
        local ok, thr = pcall(DC.effil_start, DC.avatar_worker, ch, url, path)
        if ok then
            local r = wait_for_channel(ch, 25000, thr)
            if r == nil then pcall(function() thr:cancel(0) end) end
            if not (r and r.ok) then
                DC.print("[EventScan] Не удалось скачать иконку " .. key .. ": " .. tostring(r and r.err or "timeout"))
            end
        else
            DC.print("[EventScan] Не удалось запустить загрузку иконки " .. key .. ": " .. tostring(thr))
        end
    end
    if DC.is_image_file(path) then
        DC.icon_ready[key] = true
    else
        os.remove(path)
    end
    DC.tex_dirty = true
end

function DC.icons_download()
    pcall(lfs.mkdir, DC.ICON_DIR)

    for _, base in ipairs({ "hourglass", "person", "people", "stopwatch", "coin",
                            "slot_free", "slot_busy", "slot_past" }) do
        os.remove(DC.ICON_DIR .. base .. "_src.png")
        os.remove(DC.ICON_DIR .. base .. "_src.png.ps1")
        os.remove(DC.ICON_DIR .. base .. ".png")
        for _, sz in ipairs({ 16, 24, 27, 32, 40 }) do
            os.remove(DC.ICON_DIR .. base .. "_" .. sz .. ".png")
        end
    end
    os.remove(DATA_DIR .. "espl_avatar_src.png")

    for _, v in ipairs(DC.ICON_VARIANTS) do
        local key = v.key
        DC.spawn(function()
            local ok, err = pcall(DC.icon_prepare, key)
            if not ok then
                DC.print("[EventScan] Ошибка подготовки иконки " .. key .. ": " .. tostring(err))
            end
        end)
    end
end

DC.tex_frame = imgui.OnFrame(function()
    return DC.tex_dirty or #DC.tex_trash > 0
end, function()
    DC.tex_dirty = false

    DC.tex_release()

    for key in pairs(DC.ICON_SPEC) do
        if DC.icon_ready[key] and not DC.icon_tex[key] and not DC.icon_failed[key] then
            local path = DC.icon_path(key)
            DC.trace("tex_frame: creating icon " .. tostring(key))
            local ok, t = pcall(imgui.CreateTextureFromFile, path)
            if ok and t then
                DC.icon_tex[key] = t
            else
                DC.icon_failed[key] = true
                os.remove(path)
            end
        end
    end

    if espl_panel.avatar_ready and not espl_panel.avatar_tex then
        DC.trace("tex_frame: creating avatar texture")
        local ok_tex, tex = pcall(imgui.CreateTextureFromFile, espl_panel.avatar_file)
        DC.trace("tex_frame: avatar texture ok=" .. tostring(ok_tex) .. " tex=" .. tostring(tex))
        if ok_tex and tex then
            espl_panel.avatar_tex = tex
            local ok_uv, uv0, uv1 = pcall(DC.cover_uv, espl_panel.avatar_file)
            if ok_uv and uv0 and uv1 then
                espl_panel.avatar_uv0, espl_panel.avatar_uv1 = uv0, uv1
            else
                espl_panel.avatar_uv0, espl_panel.avatar_uv1 = DC.UV0, DC.UV1
            end
        end
        espl_panel.avatar_ready = false
        if not espl_panel.avatar_tex then
            os.remove(espl_panel.avatar_file)
            DC.print("[EventScan] Не удалось создать текстуру аватарки, файл удалён.")
        end
    end
end)
DC.tex_frame.HideCursor = true

function DC.icon_get(key)
    return DC.icon_tex[key]
end

function DC.icon_params(key)
    local tex = DC.icon_tex[key]
    if not tex then return nil end
    return tex, DC.UV0, DC.UV1, DC.WHITE4, 0xFFFFFFFF
end

function DC.icon_draw(key, size)
    local tex, uv0, uv1, tint = DC.icon_params(key)
    if not tex then return false end
    imgui.Image(tex, imgui.ImVec2(size, size), uv0, uv1, tint)
    return true
end

DC.FREEZE_CD       = 5
DC.freeze_cd_until = 0

DC.TP_WIN_W = 310

DC.tp_frame = imgui.OnFrame(function() return DC.tp_timer.visible end, function()
    local remaining = 0
    if DC.tp_timer.end_epoch > 0 then
        remaining = math.max(0, DC.tp_timer.end_epoch - os.time())
    end

    local io = imgui.GetIO()
    local WIN_W = DC.TP_WIN_W

    if DC.tp_pos then
        imgui.SetNextWindowPos(imgui.ImVec2(DC.tp_pos.x, DC.tp_pos.y), imgui.Cond.Once)
    else
        imgui.SetNextWindowPos(
            imgui.ImVec2(io.DisplaySize.x * 0.17, io.DisplaySize.y * 0.70),
            imgui.Cond.Once)
    end
    imgui.SetNextWindowSize(imgui.ImVec2(WIN_W, 0), imgui.Cond.Always)

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 14)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(24, 14))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.055, 0.075, 0.055, 0.95))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(GREEN_BRIGHT))

    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse +
        imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoNav
    if not DC.cursor_unlocked then
        flags = flags + imgui.WindowFlags.NoInputs
    end

    if DC.alert_anim.visible then imgui.SetNextWindowFocus() end
    imgui.Begin('##es_tp_timer', nil, flags)

    do
        local wp = imgui.GetWindowPos()
        DC.tp_last_pos = { x = wp.x, y = wp.y }
        local tws = imgui.GetWindowSize()
        DC.tp_last_size = { x = tws.x, y = tws.y }
        if not DC.tp_pos and not DC.tp_default then
            DC.tp_default = { x = wp.x, y = wp.y }
        end
        if DC.cursor_unlocked and not imgui.IsMouseDown(0) then
            DC.pos_save_if_moved()
        end
    end

    local label_color = DC.tc(0.65, 0.75, 0.65, 1)
    local white       = imgui.ImVec4(1, 1, 1, 1)

    if toast_font then imgui.PushFont(toast_font) end
    do
        local head = u8("Телепорт:")
        local val, val_color
        if remaining == 0 then
            val, val_color = u8("Закончился."), imgui.ImVec4(1, 0.35, 0.35, 1)
        else
            val, val_color = DC.tp_timer_format(remaining), hexcol("05ff12")
        end
        local g = 8
        local isz = imgui.GetTextLineHeight()
        local hg_key = (remaining == 0) and "hourglass_red" or "hourglass_green"
        local has_icon = DC.icon_get(hg_key) ~= nil
        local total_w = imgui.CalcTextSize(head).x + g + imgui.CalcTextSize(val).x
            + (has_icon and (isz + g / 2) or 0)
        imgui.SetCursorPosX(math.floor((WIN_W - total_w) / 2 + 0.5))
        imgui.TextColored(label_color, head)
        imgui.SameLine(0, g)
        imgui.TextColored(val_color, val)
        if has_icon then
            imgui.SameLine(0, g / 2)
            DC.icon_draw(hg_key, isz)
        end
    end
    if toast_font then imgui.PopFont() end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    local function stat_row(label, value, icon)
        local l = u8(label)
        local gap = 6
        local isz = imgui.GetTextLineHeight()
        local has_icon = icon ~= nil and DC.icon_get(icon) ~= nil
        local total_w = imgui.CalcTextSize(l).x + gap + imgui.CalcTextSize(value).x
            + (has_icon and (isz + gap / 2) or 0)
        imgui.SetCursorPosX(math.floor((WIN_W - total_w) / 2 + 0.5))
        imgui.TextColored(label_color, l)
        imgui.SameLine(0, gap)
        imgui.TextColored(white, value)
        if has_icon then
            imgui.SameLine(0, gap / 2)
            DC.icon_draw(icon, isz)
        end
    end

    local lasts = 0
    if DC.tp_timer.opened_at > 0 then
        lasts = os.time() - DC.tp_timer.opened_at
    end

    do
        local l1, l2 = u8("Людей:"), u8("Всего людей:")
        local v1, v2 = tostring(DC.people_now), tostring(DC.people_max)
        local g, sep = 6, 14
        local isz = imgui.GetTextLineHeight()
        local ig  = 2
        local has1 = DC.icon_get("person") ~= nil
        local has2 = DC.icon_get("people") ~= nil
        local total_w = imgui.CalcTextSize(l1).x + g + imgui.CalcTextSize(v1).x + sep
            + imgui.CalcTextSize(l2).x + g + imgui.CalcTextSize(v2).x
            + (has1 and (isz + ig) or 0) + (has2 and (isz + ig) or 0)
        imgui.SetCursorPosX(math.floor((WIN_W - total_w) / 2 + 0.5))
        if has1 then
            DC.icon_draw("person", isz)
            imgui.SameLine(0, ig)
        end
        imgui.TextColored(label_color, l1)
        imgui.SameLine(0, g)
        imgui.TextColored(white, v1)
        imgui.SameLine(0, sep)
        if has2 then
            DC.icon_draw("people", isz)
            imgui.SameLine(0, ig)
        end
        imgui.TextColored(label_color, l2)
        imgui.SameLine(0, g)
        imgui.TextColored(white, v2)
    end

    if toast_font then imgui.PushFont(toast_font) end
    stat_row("Длится:", DC.duration_format(lasts), "stopwatch")
    if toast_font then imgui.PopFont() end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    local gap    = 8
    local btn_w  = 112
    local btn_h  = 30
    local grid_x = (WIN_W - (btn_w * 2 + gap)) / 2

    imgui.SetCursorPosX(grid_x)
    if imgui.Button("HpAll", imgui.ImVec2(btn_w, btn_h)) then
        DC.send_cmd("/hpall 100")
    end
    imgui.SameLine(0, gap)
    if imgui.Button("ArmorAll", imgui.ImVec2(btn_w, btn_h)) then
        DC.send_cmd("/armourall 100")
    end

    local now_clock = os.clock()
    local cd_left   = DC.freeze_cd_until - now_clock
    local on_cd     = cd_left > 0
    local cd_suffix = on_cd and string.format(" (%d)", math.ceil(cd_left)) or ""

    if on_cd then
        local dim = DC.tc(0.18, 0.22, 0.18, 1)
        imgui.PushStyleColor(imgui.Col.Button, dim)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, dim)
        imgui.PushStyleColor(imgui.Col.ButtonActive, dim)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 0.45))
    end

    imgui.SetCursorPosX(grid_x)
    if imgui.Button("Freez" .. cd_suffix .. "##es_freez", imgui.ImVec2(btn_w, btn_h)) and not on_cd then
        DC.send_cmd("/freezeall 100")
        DC.freeze_cd_until = os.clock() + DC.FREEZE_CD
    end
    imgui.SameLine(0, gap)
    if imgui.Button("UnFreez" .. cd_suffix .. "##es_unfreez", imgui.ImVec2(btn_w, btn_h)) and not on_cd then
        DC.send_cmd("/unfreezeall 100")
        DC.freeze_cd_until = os.clock() + DC.FREEZE_CD
    end

    if on_cd then imgui.PopStyleColor(4) end

    imgui.SetCursorPosX(grid_x)
    if imgui.Button(u8("Победитель") .. "##es_winner_btn", imgui.ImVec2(btn_w * 2 + gap, btn_h)) then
        DC.winner_show()
    end

    imgui.Spacing()

    local hint
    if DC.rebinding then
        hint = u8("Нажми новую клавишу... (" .. DC.key_name() .. " - отмена)")
    elseif DC.cursor_unlocked then
        hint = u8("Нажми " .. DC.key_name() .. " чтобы заблокировать курсор")
    else
        hint = u8("Нажми " .. DC.key_name() .. " чтобы разблокировать курсор")
    end
    local hint2 = u8("(нажми на текст для смены клавиши)")
    local hint_color = imgui.ImVec4(1, 1, 1, 0.4)

    imgui.SetCursorPosX((WIN_W - imgui.CalcTextSize(hint).x) / 2)
    imgui.TextColored(hint_color, hint)
    local h1_min, h1_max = imgui.GetItemRectMin(), imgui.GetItemRectMax()

    imgui.SetCursorPosY(imgui.GetCursorPosY() - imgui.GetStyle().ItemSpacing.y - 3)

    imgui.SetCursorPosX((WIN_W - imgui.CalcTextSize(hint2).x) / 2)
    imgui.TextColored(hint_color, hint2)
    local h2_min, h2_max = imgui.GetItemRectMin(), imgui.GetItemRectMax()

    local area_min = imgui.ImVec2(math.min(h1_min.x, h2_min.x), h1_min.y)
    local area_max = imgui.ImVec2(math.max(h1_max.x, h2_max.x), h2_max.y)

    if DC.cursor_unlocked and imgui.IsWindowHovered() and imgui.IsMouseHoveringRect(area_min, area_max) then
        imgui.SetMouseCursor(imgui.MouseCursor.Hand)
        local dl  = imgui.GetWindowDrawList()
        local col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.5))
        dl:AddLine(imgui.ImVec2(h1_min.x, h1_max.y), imgui.ImVec2(h1_max.x, h1_max.y), col, 1.0)
        dl:AddLine(imgui.ImVec2(h2_min.x, h2_max.y), imgui.ImVec2(h2_max.x, h2_max.y), col, 1.0)
        if imgui.IsMouseClicked(0) and not DC.rebinding then
            DC.rebinding = true
        end
    end

    imgui.End()

    imgui.PopStyleColor(5)
    imgui.PopStyleVar(4)
end)
DC.tp_frame.HideCursor = true
DC.ALERT_TTL   = 15
DC.ALERT_MAX   = 3
DC.ALERT_OVERLAP = 10
DC.ALERT_INSET   = 14
DC.alert_h       = 100
DC.ALERT_OPEN  = 0.30
DC.ALERT_CLOSE = 0.25

DC.alerts      = {}
DC.alert_shown = {}
DC.alert_anim  = { visible = false, p = 0 }
DC.tp_last_size = nil

function DC.alert_push(name, hp, armor)
    local now = os.clock()
    for _, a in ipairs(DC.alerts) do
        if a.name == name then
            a.hp    = a.hp or hp
            a.armor = a.armor or armor
            a.t     = now
            return
        end
    end
    DC.trace('alert: ' .. tostring(name) .. ' hp=' .. tostring(hp) .. ' armor=' .. tostring(armor))
    DC.alerts[#DC.alerts + 1] = { name = name, hp = hp, armor = armor, t = now }
    while #DC.alerts > DC.ALERT_MAX do table.remove(DC.alerts, 1) end
end

function DC.alert_remove(name)
    for i = #DC.alerts, 1, -1 do
        if DC.alerts[i].name == name then table.remove(DC.alerts, i) end
    end
end

function DC.alert_clear()
    DC.alerts      = {}
    DC.alert_shown = {}
    DC.alert_anim.visible = false
    DC.alert_anim.p       = 0
end

function DC.alert_what(a)
    if a.hp and a.armor then return u8("здоровье и броню") end
    if a.hp then return u8("здоровье") end
    return u8("броню")
end

function DC.alert_pm_reason(a)
    if a.hp and a.armor then return "ты надел броню и пополнил здоровье" end
    if a.hp then return "ты пополнил здоровье" end
    return "ты надел броню"
end

function DC.alert_kick(a)
    local name = a.name
    DC.trace('alert kick: ' .. tostring(name))
    local pm   = "/pm " .. name .. " 1 Тебя заспавнили за нарушение правил мероприятия, " .. DC.alert_pm_reason(a)
    DC.alert_remove(name)
    DC.spawn(function()
        wait(0)
        DC.say("/spplayer " .. name)
        wait(700)
        DC.say(pm)
    end)
end

DC.alert_frame = imgui.OnFrame(function()
    return DC.tp_timer.visible and (#DC.alerts > 0 or DC.alert_anim.visible)
end, function()
    local tp, ts = DC.tp_last_pos, DC.tp_last_size
    if not tp or not ts then return end

    local now = os.clock()
    for i = #DC.alerts, 1, -1 do
        if now - DC.alerts[i].t > DC.ALERT_TTL then table.remove(DC.alerts, i) end
    end

    local anim = DC.alert_anim
    local dt   = math.min(imgui.GetIO().DeltaTime, 0.1)
    if #DC.alerts > 0 then
        local copy = {}
        for i, a in ipairs(DC.alerts) do copy[i] = a end
        DC.alert_shown = copy
        anim.visible = true
        anim.p = math.min(anim.p + dt / DC.ALERT_OPEN, 1)
    else
        anim.p = math.max(anim.p - dt / DC.ALERT_CLOSE, 0)
        if anim.p <= 0 then
            anim.visible   = false
            DC.alert_shown = {}
            return
        end
    end

    local eased = 1 - (1 - anim.p) ^ 3
    local slide = DC.alert_h * (1 - eased)

    imgui.SetNextWindowPos(
        imgui.ImVec2(tp.x + DC.ALERT_INSET, tp.y + DC.ALERT_OVERLAP + slide),
        imgui.Cond.Always, imgui.ImVec2(0, 1))
    imgui.SetNextWindowSize(imgui.ImVec2(ts.x - DC.ALERT_INSET * 2, 0), imgui.Cond.Always)

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 14)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 12))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 6))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.055, 0.075, 0.055, 0.95))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(ESPL_AMBER))
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.65, 0.16, 0.16, 1))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.82, 0.22, 0.22, 1))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.95, 0.30, 0.30, 1))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))

    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar +
        imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoSavedSettings +
        imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoNav +
        imgui.WindowFlags.NoBringToFrontOnFocus
    if not DC.cursor_unlocked then
        flags = flags + imgui.WindowFlags.NoInputs
    end

    imgui.Begin('##es_hp_alert', nil, flags)

    local shown = DC.alert_shown
    for i, a in ipairs(shown) do
        local avail = imgui.GetContentRegionAvail().x
        local head  = a.name .. ":"
        local body  = u8("Пополнил ") .. DC.alert_what(a)
        local gap   = 6
        local total = imgui.CalcTextSize(head).x + gap + imgui.CalcTextSize(body).x

        if total <= avail then
            imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail - total) / 2)
            imgui.TextColored(hexcol("FFFF00"), head)
            imgui.SameLine(0, gap)
            imgui.Text(body)
        else
            center_text(head, hexcol("FFFF00"))
            center_text(body)
        end

        local left = math.max(0, math.ceil(DC.ALERT_TTL - (now - a.t)))
        local kick_label = u8("Выгнать") .. " (" .. left .. ")"
        if imgui.Button(kick_label .. "##es_kick_" .. a.name, imgui.ImVec2(avail, 30)) then
            DC.alert_kick(a)
        end

        if i < #shown then
            imgui.Spacing()
            imgui.Separator()
            imgui.Spacing()
        end
    end

    imgui.Dummy(imgui.ImVec2(0, DC.ALERT_OVERLAP))

    local aws = imgui.GetWindowSize()
    DC.alert_h = aws.y

    imgui.End()

    imgui.PopStyleColor(6)
    imgui.PopStyleVar(5)
end)
DC.alert_frame.HideCursor = true
DC.WINNER_SUM = 50
DC.test_mode  = false

DC.winner = {
    open      = false,
    focus     = false,
    error     = "",
    title_buf = imgui_new.char[128](0),
    id_buf    = imgui_new.char[8](0),
}

function DC.winner_show()
    local w = DC.winner
    DC.trace('winner window opened')
    w.title_buf[0] = 0
    w.id_buf[0]    = 0
    w.error = ""
    w.focus = true
    w.open  = true
end

function DC.winner_close()
    DC.winner.open = false
end

function DC.winner_submit()
    local w = DC.winner
    DC.trace('winner_submit: begin')

    local title = ffi.string(w.title_buf):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then
        w.error = u8("Введите название мероприятия")
        return
    end

    local id_str = ffi.string(w.id_buf)
    if not id_str:match("^%d+$") then
        w.error = u8("Введите ID игрока")
        return
    end
    local id = tonumber(id_str)
    if id > 1003 or not sampIsPlayerConnected(id) then
        w.error = u8("Игрок с ID " .. id .. " не найден")
        return
    end

    local sum = DC.WINNER_SUM

    local name = sampGetPlayerNickname(id)
    if not name or name == "" then
        w.error = u8("Player not found")
        return
    end

    local ok_dec, title_ansi = pcall(function() return u8:decode(title) end)
    if not ok_dec or not title_ansi then title_ansi = title end

    DC.last_winner = { nick = name, title = title_ansi, sum = sum, time = os.time() }

    local AO_FMT = (DC.test_mode and '/b ' or '/ao ') .. 'Победителем мероприятия "%s" стал %s и получает %dКК'
    local msg = string.format(AO_FMT, title_ansi, name, sum)

    if #msg > 140 then
        local cut = math.max(#title_ansi - (#msg - 140), 1)
        msg = string.format(AO_FMT, title_ansi:sub(1, cut), name, sum)
        if #msg > 140 then msg = msg:sub(1, 140) end
    end

    w.open = false
    w.pending = { msg = msg, name = name, sum = sum, title = title_ansi }
    DC.trace('winner_submit: pending set, nick=' .. tostring(name) .. ' sum=' .. tostring(sum) .. ' title=' .. tostring(title_ansi) .. ' msg=' .. msg)
end

function DC.winner_loop()
    DC.spawn(function()
        while true do
            wait(0)
            local p = DC.winner.pending
            if p then
                DC.winner.pending = nil
                local ok, err = pcall(function()
                    DC.trace('loop: sampSendChat /ao')
                    DC.say(p.msg)
                    DC.trace('loop: /ao sent, hiding window')
                    DC.tp_set_visible(false)
                    DC.trace('loop: window hidden, waiting')
                    wait(DC.BANK_CMD_DELAY)
                    DC.trace('loop: bank_start')
                    DC.bank_start(p.name, DC.test_mode and 1 or (p.sum * 1000000), p.title)
                    DC.trace('loop: bank_start done')
                end)
                if not ok then
                    DC.print("[EventScan] winner_loop error: " .. tostring(err))
                end
            end
        end
    end)
end

DC.winner_frame = imgui.OnFrame(function()
    return DC.winner.open and DC.tp_timer.visible
end, function()
    local w = DC.winner

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 12))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 6))
    imgui.PushStyleColor(imgui.Col.WindowBg, DC.tc(0.05, 0.08, 0.05, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))
    imgui.PushStyleColor(imgui.Col.Button, hexcol(GREEN_DARK))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hexcol(GREEN_MID))
    imgui.PushStyleColor(imgui.Col.ButtonActive, hexcol(GREEN_BRIGHT))
    imgui.PushStyleColor(imgui.Col.FrameBg, DC.tc(0.10, 0.14, 0.10, 1))

    local io = imgui.GetIO()
    imgui.SetNextWindowPos(
        imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2),
        imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowFocus()

    imgui.Begin('##es_winner_window', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.AlwaysAutoResize)

    local label_color = DC.tc(0.65, 0.75, 0.65, 1)
    local dim_color   = imgui.ImVec4(1, 1, 1, 0.35)

    local lbl_title = u8("Название")
    local lbl_id    = u8("ID")
    local label_w = math.max(
        imgui.CalcTextSize(lbl_title).x,
        imgui.CalcTextSize(lbl_id).x) + 10
    local input_w = 230
    local total_w = label_w + input_w
    local x0 = imgui.GetCursorPosX()

    local function row_label(text)
        imgui.AlignTextToFramePadding()
        imgui.TextColored(label_color, text)
        imgui.SameLine(x0 + label_w)
    end

    row_label(lbl_title)
    if w.focus then
        imgui.SetKeyboardFocusHere()
        w.focus = false
    end
    imgui.PushItemWidth(input_w)
    imgui.InputText('##es_win_title', w.title_buf, ffi.sizeof(w.title_buf))
    imgui.PopItemWidth()

    row_label(lbl_id)
    imgui.PushItemWidth(70)
    imgui.InputText('##es_win_id', w.id_buf, ffi.sizeof(w.id_buf),
        imgui.InputTextFlags.CharsDecimal)
    imgui.PopItemWidth()
    imgui.SameLine(0, 8)
    imgui.AlignTextToFramePadding()
    do
        local pid = tonumber(ffi.string(w.id_buf))
        if pid and pid >= 0 and pid <= 1003 and pid == math.floor(pid) and sampIsPlayerConnected(pid) then
            local nick_max = input_w - 70 - 8
            imgui.TextColored(hexcol(GREEN_BRIGHT),
                espl_truncate_to_width(sampGetPlayerNickname(pid), nick_max))
        else
            imgui.TextColored(dim_color, "-")
        end
    end

    if w.error ~= "" then
        center_text(w.error, imgui.ImVec4(1, 0.35, 0.35, 1))
    end

    local gap   = 8
    local btn_w = (total_w - gap) / 2
    if imgui.Button(u8("Отправить"), imgui.ImVec2(btn_w, 28)) then
        DC.winner_submit()
    end
    imgui.SameLine(0, gap)
    if imgui.Button(u8("Отмена"), imgui.ImVec2(btn_w, 28)) then
        w.open = false
    end

    imgui.End()

    imgui.PopStyleColor(7)
    imgui.PopStyleVar(5)
end)

DC.BANK_MENU_CMD      = "/abankmenu"
DC.BANK_ITEM_BALANCE  = 0
DC.BANK_ITEM_WITHDRAW = 2
DC.BANK_ITEM_TRANSFER = 3
DC.BANK_CMD_DELAY     = 700
DC.BANK_STEP_TIMEOUT  = 8
DC.BANK_FALLBACK_MS   = 300

DC.bank = { state = "idle", menu_id = nil, nick = "", title = "", amount = 0, deadline = 0, run = 0 }

function DC.bank_set(state)
    DC.trace('bank state: ' .. tostring(DC.bank.state) .. ' -> ' .. tostring(state))
    DC.bank.state    = state
    DC.bank.deadline = os.clock() + DC.BANK_STEP_TIMEOUT
end

function DC.bank_reset()
    DC.trace('bank_reset')
    DC.bank.state   = "idle"
    DC.bank.menu_id = nil
end

function DC.bank_is_list(style)  return style == 2 or style == 4 or style == 5 end
function DC.bank_is_input(style) return style == 1 or style == 3 or style == 6 end

function DC.bank_start(nick, amount, title)
    local b = DC.bank
    DC.trace('bank_start')
    b.run      = b.run + 1
    b.nick     = nick
    b.title    = title or ""
    b.amount   = amount
    b.menu_id  = nil
    DC.bank_set("menu1")

    local my_run = b.run
    DC.spawn(function()
        while DC.bank.run == my_run and DC.bank.state ~= "idle" do
            wait(250)
            if DC.bank.run == my_run and DC.bank.state ~= "idle" and os.clock() > DC.bank.deadline then
                es_msg("Банк: нет ответа от сервера, операция прервана (шаг: " .. DC.bank.state .. ")", "FF4444")
                DC.bank_reset()
            end
        end
    end)

    DC.say(DC.BANK_MENU_CMD)
end

function DC.bank_menu_fallback(expect, idx, nxt, delay)
    local my_run = DC.bank.run
    DC.spawn(function()
        wait(delay)
        local b = DC.bank
        if b.run ~= my_run or b.state ~= expect or not b.menu_id then return end
        DC.bank_set(nxt)
        DC.dlg(b.menu_id, 1, idx, "")
    end)
end

function DC.bank_apply_balance(clean, strict)
    local b = DC.bank
    if b.state ~= "balance" then return false end
    local num
    local kws = { "Состояние счета" }
    local okd, dec = pcall(function() return u8:decode(kws[1]) end)
    if okd and dec then kws[2] = dec end
    for _, kw in ipairs(kws) do
        local _, e = clean:find(kw, 1, true)
        if e then num = clean:sub(e + 1):match("(%d[%d%.]*)") break end
    end
    if not num and not strict then num = clean:match("(%d[%d%.]*)") end
    if not num then return false end
    local balance = tonumber((num:gsub("%.", "")))
    if not balance then return false end
    DC.trace("bank: balance=" .. tostring(balance) .. " need=" .. tostring(b.amount))

    if balance < b.amount then
        DC.bank_set("menu_withdraw")
        DC.bank_menu_fallback("menu_withdraw", DC.BANK_ITEM_WITHDRAW, "withdraw_input", DC.BANK_FALLBACK_MS)
    else
        DC.bank_set("menu_transfer")
        DC.bank_menu_fallback("menu_transfer", DC.BANK_ITEM_TRANSFER, "nick_input", DC.BANK_FALLBACK_MS)
    end
    return true
end

function DC.bank_on_message(clean)
    if DC.bank.state ~= "balance" then return end
    if not DC.has_text(clean, "Состояние счета") then return end
    DC.bank_apply_balance(clean, true)
end

function DC.bank_send(id, button, item, text)
    DC.spawn(function()
        wait(0)
        DC.trace('send dialog response id=' .. tostring(id) .. ' btn=' .. tostring(button) .. ' item=' .. tostring(item))
        local ok, err = pcall(DC.dlg, id, button, item, text)
        DC.trace('dialog response sent ok=' .. tostring(ok))
        if not ok then DC.print("[EventScan] sampSendDialogResponse error: " .. tostring(err)) end
    end)
end

function DC.sampev_onShowDialog(id, style, title, button1, button2, text)
    DC.trace('onShowDialog id=' .. tostring(id) .. ' style=' .. tostring(style) .. ' title=' .. tostring(title):sub(1, 60) .. ' bank=' .. tostring(DC.bank.state))
    local b  = DC.bank
    local st = b.state
    if st == "idle" then return end
    DC.trace("dialog id=" .. tostring(id) .. " style=" .. tostring(style) .. " state=" .. tostring(st))

    if DC.bank_is_list(style) then
        b.menu_id = id
        if st == "menu1" then
            DC.bank_set("balance")
            DC.bank_send(id, 1, DC.BANK_ITEM_BALANCE, "")
            return false
        elseif st == "balance" then
            return false
        elseif st == "menu_withdraw" then
            DC.bank_set("withdraw_input")
            DC.bank_send(id, 1, DC.BANK_ITEM_WITHDRAW, "")
            return false
        elseif st == "menu_transfer" then
            DC.bank_set("nick_input")
            DC.bank_send(id, 1, DC.BANK_ITEM_TRANSFER, "")
            return false
        elseif st == "nick_input" or st == "withdraw_input" then

            DC.trace("late menu dialog swallowed, state=" .. tostring(st))
            return false
        elseif st == "closing" then
            DC.bank_send(id, 0, 65535, "")
            DC.bank_reset()
            return false
        end

    elseif DC.bank_is_input(style) then
        if st == "withdraw_input" then
            DC.bank_set("menu_transfer")
            DC.bank_send(id, 1, 65535, string.format("%d", b.amount))
            DC.bank_menu_fallback("menu_transfer", DC.BANK_ITEM_TRANSFER, "nick_input", DC.BANK_FALLBACK_MS)
            return false
        elseif st == "nick_input" then
            DC.bank_set("sum_input")
            DC.bank_send(id, 1, 65535, b.nick)
            return false
        elseif st == "sum_input" then
            DC.bank_set("closing")
            DC.bank_send(id, 1, 65535, string.format("%d", b.amount))
            local ess_title, ess_nick = b.title, b.nick
            DC.auto_es(DC.AUTO_ES_DELAY, function(ok)
                if ok then DC.auto_ess(ess_title, ess_nick) end
            end)

            local my_run = b.run
            DC.spawn(function()
                wait(2500)
                local bb = DC.bank
                if bb.run == my_run and bb.state == "closing" then
                    DC.trace('bank watchdog: closing')
                    local okd, active = pcall(function()
                        return sampIsDialogActive() and sampGetCurrentDialogId() == bb.menu_id
                    end)
                    if bb.menu_id and okd and active then
                        pcall(DC.dlg, bb.menu_id, 0, 65535, "")
                    end
                    DC.bank_reset()
                    DC.trace('bank watchdog: done')
                end
            end)
            return false
        end
    end

    DC.bank_reset()
    es_msg(string.format("Банк: неожиданный диалог (шаг {FFFF00}%s{FFFFFF}, style {FFFF00}%s{FFFFFF}, id {FFFF00}%s{FFFFFF}). Операция прервана.",
        tostring(st), tostring(style), tostring(id)), "FFAA00")
end

DC.AUTO_ES_DELAY = 1000
DC.tp_armed      = false

function DC.auto_es(delay, on_done)
    DC.spawn(function()
        wait(delay or DC.AUTO_ES_DELAY)
        DC.trace('auto_es fire')
        if DC.es_handler then
            DC.require(function() DC.es_handler(on_done) end)
        end
    end)
end

function DC.auto_ess(title, nick)
    DC.trace('auto_ess')
    DC.require(function()
        if not DC.ess_handler then return end
        local ok, err = pcall(DC.ess_handler, title .. " " .. nick)
        if not ok then DC.print("[EventScan] auto /ess error: " .. tostring(err)) end
    end)
end

function DC.tp_watch_start()
    DC.spawn(function()
        while true do
            wait(200)
            local t = DC.tp_timer
            if DC.tp_armed and t.end_epoch > 0 and os.time() >= t.end_epoch then
                DC.tp_armed = false
                DC.trace('teleport timer finished, scan prompt shown')
                DC.scan_prompt_show()
            end
        end
    end)
end

DC.SCAN_PROMPT_TTL   = 15
DC.SCAN_PROMPT_OPEN  = 0.30
DC.SCAN_PROMPT_CLOSE = 0.25

DC.scan_prompt = { open = false, closing = false, opened_at = 0, close_at = 0 }

function DC.scan_prompt_show()
    local sp = DC.scan_prompt
    sp.opened_at = os.clock()
    sp.closing   = false
    sp.open      = true
end

function DC.scan_prompt_close()
    local sp = DC.scan_prompt
    if sp.open and not sp.closing then
        sp.closing  = true
        sp.close_at = os.clock()
    end
end

function DC.scan_prompt_accept()
    local sp = DC.scan_prompt
    DC.trace('scan prompt: Enter pressed (open=' .. tostring(sp.open) .. ' closing=' .. tostring(sp.closing) .. ')')
    if not sp.open or sp.closing then return end

    sp.open    = false
    sp.closing = false
    DC.auto_es(150)
end

function DC.scan_prompt_loop()
    DC.spawn(function()
        local chat_was_active = false
        while true do
            wait(0)
            local chat_now = sampIsChatInputActive()
            local sp = DC.scan_prompt
            if sp.open and not sp.closing then
                if os.clock() - sp.opened_at >= DC.SCAN_PROMPT_TTL then
                    DC.scan_prompt_close()
                else

                    local blocked = chat_now or chat_was_active
                        or sampIsDialogActive() or DC.winner.open
                    if not blocked and wasKeyPressed(vkeys.VK_RETURN) then
                        DC.scan_prompt_accept()
                    end
                end
            end
            chat_was_active = chat_now
        end
    end)
end

DC.scan_prompt_frame = imgui.OnFrame(function() return DC.scan_prompt.open end, function()
    local sp  = DC.scan_prompt
    local now = os.clock()

    local p
    if sp.closing then
        local t = math.min((now - sp.close_at) / DC.SCAN_PROMPT_CLOSE, 1.0)
        if t >= 1.0 then
            sp.open    = false
            sp.closing = false
            return
        end
        p = (1.0 - t) ^ 3
    else
        local t = math.min((now - sp.opened_at) / DC.SCAN_PROMPT_OPEN, 1.0)
        p = 1 - (1 - t) ^ 3
    end

    local left = math.max(0, math.ceil(DC.SCAN_PROMPT_TTL - (now - sp.opened_at)))

    local part1 = u8("Сделать скан: ")
    local part2 = "Enter"
    local part3 = " (" .. left .. ")"

    local using_font = toast_font ~= nil
    if using_font then imgui.PushFont(toast_font) end
    local w1 = imgui.CalcTextSize(part1).x
    local w2 = imgui.CalcTextSize(part2).x
    local w3 = imgui.CalcTextSize(part3).x
    local max_w = w1 + w2 + imgui.CalcTextSize(" (" .. DC.SCAN_PROMPT_TTL .. ")").x
    local line_h = imgui.GetTextLineHeight()
    if using_font then imgui.PopFont() end

    local win_w = max_w + TOAST_PAD * 2 + 24
    local win_h = 40
    local io = imgui.GetIO()
    local screen_w, screen_h = io.DisplaySize.x, io.DisplaySize.y

    local final_y = screen_h - win_h - 8
    local pos_y   = final_y + 30 * (1 - p)
    local alpha   = 0.97 * p

    imgui.SetNextWindowPos(imgui.ImVec2(screen_w / 2, pos_y), imgui.Cond.Always, imgui.ImVec2(0.5, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(win_w, win_h), imgui.Cond.Always)
    imgui.SetNextWindowBgAlpha(alpha)

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 18)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(10, 8))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.0, 0.0, 0.0, 0.0))
    local bc = hexcol(GREEN_MID)
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(bc.x, bc.y, bc.z, p))

    imgui.Begin('##es_scan_prompt', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove +
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings +
        imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoNav)

    local dl  = imgui.GetWindowDrawList()
    local wp  = imgui.GetWindowPos()
    local wsz = imgui.GetWindowSize()
    local gap = 3
    dl:AddRectFilled(
        imgui.ImVec2(wp.x + gap, wp.y + gap),
        imgui.ImVec2(wp.x + wsz.x - gap, wp.y + wsz.y - gap),
        imgui.ColorConvertFloat4ToU32(DC.tc(0.06, 0.09, 0.06, alpha)), 15)

    if using_font then imgui.PushFont(toast_font) end

    imgui.SetCursorPosY((wsz.y - line_h) / 2)
    imgui.SetCursorPosX(math.floor((wsz.x - (w1 + w2 + w3)) / 2 + 0.5))

    local g = hexcol(GREEN_BRIGHT)
    imgui.TextColored(imgui.ImVec4(1, 1, 1, p), part1)
    imgui.SameLine(0, 0)
    imgui.TextColored(imgui.ImVec4(g.x, g.y, g.z, p), part2)
    imgui.SameLine(0, 0)
    imgui.TextColored(imgui.ImVec4(1, 1, 1, 0.6 * p), part3)

    if using_font then imgui.PopFont() end

    imgui.End()

    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end)
DC.scan_prompt_frame.HideCursor = true

DC.OFFLINE_FILE = DATA_DIR .. "pending_reports.json"

function DC.offline_load()
    local f = io.open(DC.OFFLINE_FILE, "rb")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(dkjson.decode, content)
    if ok and type(data) == "table" then return data end
    return {}
end

function DC.offline_write(list)
    local tmp = DC.OFFLINE_FILE .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(dkjson.encode(list, { indent = true }))
    f:close()
    os.remove(DC.OFFLINE_FILE)
    return os.rename(tmp, DC.OFFLINE_FILE) and true or false
end

function DC.offline_save(payload)
    DC.trace('offline_save: report stored locally')
    local list = DC.offline_load()

    local meta = {}
    local lw = DC.last_winner
    if lw and payload.winner and tostring(payload.winner):lower() == tostring(lw.nick):lower() then
        meta.sum_kk = lw.sum
    end

    list[#list + 1] = {
        id      = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
        created = get_readable_time(),
        tries   = 0,
        payload = payload,
        meta    = meta
    }
    return DC.offline_write(list)
end

function DC.offline_remove(id)
    local list = DC.offline_load()
    for i = #list, 1, -1 do
        if list[i].id == id then table.remove(list, i) end
    end
    DC.offline_write(list)
end

function DC.offline_update(entry)
    local list = DC.offline_load()
    for i, e in ipairs(list) do
        if e.id == entry.id then list[i] = entry break end
    end
    DC.offline_write(list)
end

function DC.deliver(payload)
    DC.trace('deliver: event=' .. tostring(payload.event) .. ' winner=' .. tostring(payload.winner) .. ' scans=' .. #(payload.scans or {}) .. ' players=' .. #(payload.players or {}))
    local hwid = get_hwid()
    if not hwid then return { ok = false, err = "no_hwid" } end

    for _, sc in ipairs(payload.scans or {}) do
        if not sc.url and sc.path then
            local f = io.open(sc.path, "rb")
            if f then
                local data = f:read("*a")
                f:close()
                local r = try_worker_urls(screenshot_upload_worker, function(url)
                    return { data, hwid, DC.DEBUG and DC.LOG_FILE or "" }
                end, 20000)
                if r and r.ok and r.url then
                    sc.url  = r.url
                    sc.path = nil
                else
                    return { ok = false, err = (r and r.err) or "timeout" }
                end
            else
                sc.lost = true
            end
        end
    end

    local clean_scans = {}
    for _, sc in ipairs(payload.scans or {}) do
        if sc.url then clean_scans[#clean_scans + 1] = { time = sc.time, url = sc.url } end
    end

    local body = dkjson.encode({
        date    = payload.date,
        time    = payload.time,
        event   = payload.event,
        winner  = payload.winner,
        author  = payload.author,
        players = payload.players,
        scans   = clean_scans
    })

    return try_worker_urls(d1_report_worker, function(url)
        return { body, hwid }
    end, 20000)
end

function DC.send_report(payload, on_done)
    DC.trace('send_report start')
    local hwid = get_hwid()
    if not hwid then
        es_msg("HWID ещё определяется в фоне — попробуй отправить отчёт через пару секунд.", "FFAA00")
        if on_done then on_done(false) end
        return
    end

    show_ess_toast(u8("Отправка..."), GREEN_BRIGHT)

    DC.spawn(function()
        local result = DC.deliver(payload)
        DC.trace('deliver finished ok=' .. tostring(result and result.ok) .. ' err=' .. tostring(result and result.err))
        if result and result.ok then
            show_ess_toast(u8("Готово!"), GREEN_BRIGHT)
            wait(2000)
            hide_ess_toast()
            es_msg("Отчёт успешно сохранён в базу данных!")
            if on_done then on_done(true) end
            return
        end

        local err = result and result.err or "timeout"
        if is_hwid_error(err) then
            show_ess_toast(u8("Ошибка HWID!"), "FF4444")
            wait(2000)
            hide_ess_toast()
            notify_hwid_denied()
            if on_done then on_done(false) end
            return
        end

        DC.offline_save(payload)
        show_ess_toast(u8("Сохранено"), "FFAA00")
        wait(2000)
        hide_ess_toast()
        es_msg("Сервер недоступен (" .. tostring(err) .. "). Отчёт сохранён локально и будет отправлен при следующем запуске скрипта.", "FFAA00")
        if on_done then on_done(true) end
    end)
end

function DC.offline_flush()
    DC.spawn(function()
        wait(5000)
        local waited = 0
        while not get_hwid() and waited < 60000 do
            wait(500)
            waited = waited + 500
        end
        if not get_hwid() then return end

        local list = DC.offline_load()
        if #list == 0 then return end
        DC.print(string.format("[EventScan] В локальной очереди отчётов: %d. Пробую отправить...", #list))

        local sent = 0
        for _, entry in ipairs(list) do
            if type(entry.payload) ~= "table" or type(entry.payload.scans) ~= "table" then
                DC.offline_remove(entry.id)
            else
                local result = DC.deliver(entry.payload)
                if result and result.ok then
                    DC.offline_remove(entry.id)
                    sent = sent + 1
                else
                    entry.tries = (entry.tries or 0) + 1
                    DC.offline_update(entry)
                    local err = result and result.err or "timeout"
                    DC.print("[EventScan] Отложенный отчёт не отправлен: " .. tostring(err))
                    if is_hwid_error(err) or is_network_failure(result) then break end
                end
            end
        end

        if sent > 0 then
            es_msg(string.format("Отправлено отложенных отчётов: {FFFF00}%d{FFFFFF}.", sent))
        end
    end)
end

DC.hp_cache    = {}
DC.HP_EPSILON  = 0.5
DC.HP_POLL_MS  = 100
DC.HP_APPEAR_GRACE = 1000

DC.HP_WINDOW_BEFORE = 1000
DC.HP_WINDOW_AFTER  = 200
DC.give_times       = {}
DC.hp_pending       = {}

function DC.now_ms()
    return os.clock() * 1000
end

function DC.has_text(clean, str)
    if clean:find(str, 1, true) then return true end
    local ok, dec = pcall(function() return u8:decode(str) end)
    if ok and dec and clean:find(dec, 1, true) then return true end
    return false
end

function DC.give_register(clean)
    if not clean:find("[A]", 1, true) then return end
    if not DC.has_text(clean, "выдал броню") then return end
    if not DC.has_text(clean, "игрокам") then return end

    local nick = clean:match("%[A%]%s*(%S+)")
    if not nick then return end
    if nick:lower() ~= get_local_nickname():lower() then return end

    DC.give_times[#DC.give_times + 1] = DC.now_ms()
end

function DC.give_in_window(t)
    for _, gt in ipairs(DC.give_times) do
        if gt >= t - DC.HP_WINDOW_BEFORE and gt <= t + DC.HP_WINDOW_AFTER then
            return true
        end
    end
    return false
end

function DC.hp_flush_pending()
    local now = DC.now_ms()

    for i = #DC.give_times, 1, -1 do
        if now - DC.give_times[i] > 5000 then table.remove(DC.give_times, i) end
    end

    for i = #DC.hp_pending, 1, -1 do
        local p = DC.hp_pending[i]
        if now - p.t >= DC.HP_WINDOW_AFTER then
            if not DC.give_in_window(p.t) then
                DC.alert_push(p.name, p.hp, p.armor)
            end
            table.remove(DC.hp_pending, i)
        end
    end
end

function DC.hp_reset()
    DC.hp_cache   = {}
    DC.hp_pending = {}
end

function DC.hp_scan_once()
    local myX, myY, myZ = getCharCoordinates(PLAYER_PED)
    local seen = {}

    for id = 0, 1000 do
        if sampIsPlayerConnected(id) then
            local result, ped = sampGetCharHandleBySampPlayerId(id)
            if result and doesCharExist(ped) and ped ~= PLAYER_PED then
                local x, y, z = getCharCoordinates(ped)
                if distance3d(x, y, z, myX, myY, myZ) <= SCAN_RADIUS then
                    seen[id] = true

                    local name  = sampGetPlayerNickname(id)
                    local hp    = tonumber(sampGetPlayerHealth(id)) or 0
                    local armor = tonumber(sampGetPlayerArmor(id)) or 0
                    local prev  = DC.hp_cache[id]

                    if prev and prev.name == name then
                        local settled  = DC.now_ms() - (prev.t0 or 0) >= DC.HP_APPEAR_GRACE
                        local hp_up    = settled and prev.hp > 0 and (hp - prev.hp) > DC.HP_EPSILON
                        local armor_up = settled and (armor - prev.armor) > DC.HP_EPSILON

                        if hp_up or armor_up then
                            DC.hp_pending[#DC.hp_pending + 1] = { t = DC.now_ms(), name = name, hp = hp_up, armor = armor_up }
                        end

                        prev.hp, prev.armor = hp, armor
                    else
                        DC.hp_cache[id] = { name = name, hp = hp, armor = armor, t0 = DC.now_ms() }
                    end
                end
            end
        end
    end

    local cnt = 0
    for _ in pairs(seen) do cnt = cnt + 1 end
    DC.people_now = cnt
    if cnt > DC.people_max then DC.people_max = cnt end

    for id in pairs(DC.hp_cache) do
        if not seen[id] then DC.hp_cache[id] = nil end
    end
end

function DC.hp_start_loop()
    DC.spawn(function()
        while true do
            if DC.tp_timer.visible then
                local ok, err = pcall(DC.hp_scan_once)
                if not ok then
                    DC.print("[EventScan] Ошибка слежения за ХП/бронёй: " .. tostring(err))
                end
                pcall(DC.hp_flush_pending)
            else
                if next(DC.hp_cache) ~= nil or #DC.hp_pending > 0 then DC.hp_reset() end
            end
            wait(DC.HP_POLL_MS)
        end
    end)
end

DC.SESSION_FILE    = DATA_DIR .. "session_state.json"
DC.SESSION_MAX_AGE = 6 * 3600
DC.session_ready   = false
DC.session_last    = nil
DC.session_last_t  = 0

function DC.s_enc(v)
    if type(v) ~= "string" or v == "" then return v end
    return to_utf8(v)
end

function DC.s_dec(v)
    if type(v) ~= "string" or v == "" then return v end
    local ok, r = pcall(function() return u8:decode(v) end)
    if ok and r then return r end
    return v
end

function DC.session_collect()
    local scans, players, reports = {}, {}, {}
    for _, s in ipairs(pending_scans) do
        scans[#scans + 1] = { time = s.time, url = s.url, path = DC.s_enc(s.path) }
    end
    for _, n in ipairs(unique_players_order) do
        players[#players + 1] = DC.s_enc(n)
    end
    for _, r in ipairs(pending_reports) do
        reports[#reports + 1] = DC.s_enc(r)
    end

    local t  = DC.tp_timer
    local lw = DC.last_winner
    return {
        scans    = scans,
        players  = players,
        reports  = reports,
        scanning = scanning_active and true or false,
        timer = {
            visible    = t.visible and true or false,
            end_epoch  = t.end_epoch,
            total      = t.total,
            opened_at  = t.opened_at,
            people_max = DC.people_max,
            armed      = DC.tp_armed and true or false,
        },
        winner = lw and {
            nick  = DC.s_enc(lw.nick),
            title = DC.s_enc(lw.title),
            sum   = lw.sum,
            time  = lw.time,
        } or nil,
    }
end

function DC.session_clear_files()
    DC.trace('session files cleared')
    os.remove(DC.SESSION_FILE)
    os.remove(DC.SESSION_FILE .. ".tmp")
end

function DC.session_save(force)
    local st = DC.session_collect()

    local empty = #st.scans == 0 and #st.players == 0 and #st.reports == 0
        and not st.timer.visible
    if empty then
        if DC.session_last ~= "" then
            DC.session_clear_files()
            DC.session_last = ""
        end
        return
    end

    local body = dkjson.encode(st)
    local now  = os.clock()
    if not force and body == DC.session_last and now - DC.session_last_t < 30 then
        return
    end

    st.saved_at = os.time()
    local tmp = DC.SESSION_FILE .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(dkjson.encode(st))
    f:close()
    os.remove(DC.SESSION_FILE)
    if os.rename(tmp, DC.SESSION_FILE) then
        DC.trace('session saved: bytes=' .. #body .. ' scans=' .. #st.scans .. ' players=' .. #st.players)
        DC.session_last   = body
        DC.session_last_t = now
    end
end

function DC.session_read()
    for _, p in ipairs({ DC.SESSION_FILE, DC.SESSION_FILE .. ".tmp" }) do
        local f = io.open(p, "rb")
        if f then
            local c = f:read("*a")
            f:close()
            local ok, d = pcall(dkjson.decode, c or "")
            if ok and type(d) == "table" then return d end
        end
    end
    return nil
end

function DC.session_restore()
    local d = DC.session_read()
    if not d then return false end

    if os.time() - (tonumber(d.saved_at) or 0) > DC.SESSION_MAX_AGE then
        DC.session_clear_files()
        return false
    end

    local scans = {}
    for _, s in ipairs(d.scans or {}) do
        local path = DC.s_dec(s.path)
        local alive = s.url ~= nil
        if not alive and path then
            local ok_a, attr = pcall(lfs.attributes, path)
            alive = ok_a and attr and attr.mode == "file"
        end
        if alive then
            scans[#scans + 1] = { time = s.time, url = s.url, path = (not s.url) and path or nil }
        end
    end
    for _, s in ipairs(pending_scans) do scans[#scans + 1] = s end
    pending_scans = scans

    local reports = {}
    for _, r in ipairs(d.reports or {}) do reports[#reports + 1] = DC.s_dec(r) end
    for _, r in ipairs(pending_reports) do reports[#reports + 1] = r end
    pending_reports = reports

    local order, seen = {}, {}
    for _, n in ipairs(d.players or {}) do
        n = DC.s_dec(n)
        if n and not seen[n] then seen[n] = true; order[#order + 1] = n end
    end
    for _, n in ipairs(unique_players_order) do
        if not seen[n] then seen[n] = true; order[#order + 1] = n end
    end
    unique_players_order = order
    unique_players = seen

    if type(d.winner) == "table" and d.winner.nick then
        DC.last_winner = {
            nick  = DC.s_dec(d.winner.nick),
            title = DC.s_dec(d.winner.title),
            sum   = d.winner.sum,
            time  = d.winner.time,
        }
    end

    local tm = d.timer
    if type(tm) == "table" and tm.visible and tonumber(tm.end_epoch) then
        DC.tp_timer.total     = tonumber(tm.total) or 0
        DC.tp_timer.end_epoch = tonumber(tm.end_epoch)
        DC.tp_timer.opened_at = tonumber(tm.opened_at) or os.time()
        DC.tp_timer.visible   = true
        DC.people_max         = math.max(tonumber(tm.people_max) or 0, DC.people_max, #unique_players_order)
        DC.tp_armed           = tm.armed and true or false
        DC.tp_save()
    end

    DC.trace('session restored: scans=' .. #pending_scans .. ' players=' .. #unique_players_order .. ' reports=' .. #pending_reports)
    if d.scanning then start_detection_loop() end

    return true
end

function DC.session_reset()
    DC.trace('session reset (/esc)')
    stop_detection_loop()
    pending_scans        = {}
    pending_reports      = {}
    unique_players       = {}
    unique_players_order = {}
    DC.last_winner       = nil
    DC.tp_armed          = false
    DC.tp_timer.end_epoch = 0
    DC.tp_timer.total     = 0
    DC.tp_timer.opened_at = 0
    DC.tp_save()
    DC.tp_set_visible(false)
    DC.people_now = 0
    DC.people_max = 0
    DC.session_clear_files()
    DC.session_last = ""
end

function DC.session_start()
    DC.spawn(function()

        if type(sampGetGamestate) == "function" then
            local waited = 0
            while waited < 90000 do
                local ok, gs = pcall(sampGetGamestate)
                if ok and gs == 3 then break end
                wait(500)
                waited = waited + 500
            end
        end

        local ok, res = pcall(DC.session_restore)
        if not ok then DC.print("[EventScan] Ошибка восстановления сессии: " .. tostring(res)) end
        DC.session_ready = true

        if ok and res then
            show_ess_toast(u8("Сессия восстановлена. /esc - сбросить"), GREEN_BRIGHT)
            wait(5000)
            hide_ess_toast()
        end

        while true do
            wait(1000)
            local ok2, err2 = pcall(DC.session_save)
            if not ok2 then DC.print("[EventScan] Ошибка сохранения сессии: " .. tostring(err2)) end
        end
    end)
end

function onScriptTerminate(scr, quit_game)
    if scr == thisScript() then
        DC.trace('SCRIPT TERMINATE quit_game=' .. tostring(quit_game))
        if DC.session_ready then pcall(DC.session_save, true) end
        scanning_active = false
        pcall(DC.pos_save_if_moved)
        DC.trace('terminate: ethreads=' .. #DC.ethreads .. ' lthreads=' .. #DC.lthreads .. ' inflight=' .. DC.inflight)
        pcall(DC.restore_wrappers)
        pcall(DC.pool_stop)
        DC.cancel_all()
        DC.trace('terminate: effil threads cancelled, wrappers restored')
        if DC.LOG_FH then pcall(function() DC.LOG_FH:close() end) DC.LOG_FH = nil end
    end
end

function main()
    DC.trace('main: waiting for SAMP')
    DC.worker_names = {
        [DC.avatar_worker]          = "avatar_download",
        [DC.esp_wait_worker]        = "esp_wait",
        [screenshot_upload_worker]  = "upload_screenshot",
        [d1_report_worker]          = "send_report",
        [gen_token_worker]          = "gen_token",
        [d1_last_report_worker]     = "last_report",
        [plan_fetch_worker]         = "plan_fetch",
        [plan_save_worker]          = "plan_save",
        [plan_delete_worker]        = "plan_delete",
        [check_hwid_worker]         = "check_hwid",
        [my_stats_worker]           = "my_stats",
        [version_check_worker]      = "version_check",
        [update_download_worker]    = "update_download",
        [open_url_worker]           = "open_url",
        [browse_folder_worker]      = "browse_folder",
        [generate_hwid_worker]      = "generate_hwid",
    }
    while not isSampAvailable() do wait(100) end
    do
        local ok, sname = pcall(sampGetCurrentServerName)
        DC.trace('main: SAMP available, server=' .. tostring(ok and sname or '?'))
    end

    resolve_screens_root(function(path)
        screens_root_folder = path
    end)

    DC.icons_download()

    resolve_hwid(function(h)
        DC.trace('hwid resolved: ' .. tostring(h):sub(1, 8) .. '...')
        resolve_espl_author()
    end)
    DC.offline_flush()
    check_for_update()

    es_msg("{FFFF00}/es {FFFFFF}(добавить скан), {FFFF00}")
    es_msg("{FFFF00}/ess Название Ник_Победителя {FFFFFF}(Отправить отчет)")
    es_msg("{FFFF00}/eslast {FFFFFF}(время с последнего отчёта)")
    es_msg("{FFFF00}/esr {FFFFFF}(открыть CRM-дашборд твоих отчётов)")
    es_msg("{FFFF00}/esp {FFFFFF}(открыть планировщик событий в игре)")
    es_msg("{FFFF00}/esreset {FFFFFF}(сбросить кеш папки скриншотов)")

    DC.es_handler = function(on_done)
        DC.trace('es_handler start')
        local done = type(on_done) == "function" and on_done or nil
        start_detection_loop()

        capture_and_upload_screenshot(function(screen_url, local_path)
            if not screen_url and not local_path then
                if done then done(false) end
                return
            end

            local lines = {
                string.format("--- Скан #%d | %s ---", #pending_reports + 1, get_readable_time()),
                "Screenshot: " .. (screen_url or ("[не загружен, файл: " .. tostring(local_path) .. "]"))
            }

            table.insert(pending_scans, {
                time = os.date("!%H:%M:%S", os.time() + 10800),
                url  = screen_url,
                path = (not screen_url) and local_path or nil
            })

            table.insert(pending_reports, table.concat(lines, "\n"))
            DC.trace("es_handler: saving session")

            if DC.session_ready then pcall(DC.session_save, true) end
            DC.trace("es_handler: session saved")

            if done then done(true) end
        end)
    end

    sampRegisterChatCommand("es", DC.es_handler)

    DC.ess_handler = function(params)
        DC.trace('ess_handler start')
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

        DC.send_report(payload, function(success)
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
    end
    sampRegisterChatCommand("ess", DC.ess_handler)

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

        DC.spawn(function()

            local gen_result = try_worker_urls(gen_token_worker, function(url)
                return { hwid, "esr" }
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

            local channel = effil.channel()
            local thr = DC.effil_start(open_url_worker, channel, url)

            local result = wait_for_channel(channel, 5000, thr)
            if result and result.ok then
                es_msg("Открываю твой профиль в CRM ({FFFF00}" .. nick .. "{FFFFFF})...")
            else
                es_msg("Не удалось открыть браузер (" .. tostring(result and result.err or "timeout") .. ").", "FF4444")
                es_msg("Ссылка для ручного открытия (действует не дольше 1 минуты): {FFFF00}" .. url)
            end
        end)
    end)

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

        DC.spawn(function()
            local gen_result = try_worker_urls(gen_token_worker, function(url)
                return { hwid, "esr" }
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

    sampRegisterChatCommand("esp", function()
        DC.trace("esp: handler, open=" .. tostring(espl_open[0]))
        do
            local okd, dact = pcall(sampIsDialogActive)
            local okc, cact = pcall(sampIsChatInputActive)
            DC.trace(string.format("esp: state dialog=%s chat=%s bank=%s tp_visible=%s cursor_unlocked=%s winner_open=%s alerts=%d ethreads=%d lthreads=%d mem=%.0fKB egc=%s",
                tostring(okd and dact), tostring(okc and cact), tostring(DC.bank.state), tostring(DC.tp_timer.visible),
                tostring(DC.cursor_unlocked), tostring(DC.winner.open), #DC.alerts, #DC.ethreads, #DC.lthreads, collectgarbage("count"), DC.egc_info()))
        end
        if not DC.tp_timer.visible then

            pcall(DC.tp_set_cursor, false)
            DC.winner.open = false
        end
        if espl_open[0] then
            espl_open[0]    = false
            espl_modal_open = false
            DC.esp_stop_polling()
            return
        end

        local hwid = get_hwid()
        if not hwid then
            es_msg("HWID ещё не определён. Попробуй через пару секунд.", "FFAA00")
            return
        end
        if not (espl_panel.avatar_tex or espl_panel.avatar_ready) then
            cleanup_old_avatar_files()
            espl_panel.avatar_url   = nil
            DC.tex_discard()
            espl_panel.avatar_ready = false
            espl_panel.avatar_tries = 0
        end
        resolve_espl_author()

        DC.color_open      = false
        espl_dates         = espl_get_date_range()
        espl_selected_date = format_date_ymd(os.time() + MSK_OFFSET)
        espl_schedule       = {}
        espl_top3            = {}
        espl_loading        = true
        espl_load_error      = ""
        espl_open[0] = true
        DC.espl_trace_left = 6
        DC.trace("esp: window opened")

        DC.esp_start_polling(espl_selected_date)
        DC.trace("esp: polling started")
    end)

    do
        local ok_ev, sampev = pcall(require, "samp.events")
        if ok_ev and sampev then
            sampev.onServerMessage = function(...)
                local ok, err = pcall(DC.sampev_onServerMessage, ...)
                if not ok then DC.print("[EventScan] onServerMessage error: " .. tostring(err)) end
            end
            sampev.onShowDialog = function(...)
                local ok, res = pcall(DC.sampev_onShowDialog, ...)
                if not ok then
                    DC.print("[EventScan] onShowDialog error: " .. tostring(res))
                    pcall(DC.bank_reset)
                    return nil
                end
                return res
            end
        else
            DC.print("[EventScan] samp.events не найден: слежение за чатом не работает")
        end
    end

    DC.tp_load()
    DC.auto_load()
    DC.key_load()
    DC.pos_load()
    DC.hp_start_loop()
    DC.tp_watch_start()
    DC.cursor_start_loop()
    DC.scan_prompt_loop()
    DC.winner_loop()
    DC.heartbeat_start()
    DC.state_watch_start()
    DC.effil_gc_loop()
    DC.session_start()

    DC.raw_register("ehelper", function(params)
        DC.trace("command: /ehelper params=" .. tostring(params))
        local secs = tonumber(tostring(params or ""):match("%d+"))
        if secs and secs > 0 then
            secs = math.min(secs, 86400)
            DC.tp_timer.total     = secs
            DC.tp_timer.end_epoch = os.time() + secs
            DC.tp_set_visible(true)
            DC.tp_save()
            DC.tp_armed = true
            return
        end
        DC.tp_set_visible(not DC.tp_timer.visible)
    end)

    sampRegisterChatCommand("-ehelper", function()
        DC.auto_mode = not DC.auto_mode
        DC.auto_save()
        DC.trace("auto mode = " .. tostring(DC.auto_mode))
        if DC.auto_mode then
            es_msg("Авто-режим {FFFF00}ВКЛЮЧЁН{FFFFFF}: окно помощника будет открываться при запуске мероприятия.")
        else
            es_msg("Авто-режим {FFFF00}ВЫКЛЮЧЕН{FFFFFF}: окно само не открывается, отчёты через {FFFF00}/es{FFFFFF}, {FFFF00}/ess{FFFFFF}. Открыть окно вручную: {FFFF00}/ehelper{FFFFFF}.")
        end
    end)

    DC.raw_register("etest", function()
        es_msg("Скрытые команды тестера:")
        es_msg("{FFFF00}/ehelper [сек] {FFFFFF}- окно помощника мероприятий (с числом: запуск таймера телепорта)")
        es_msg("{FFFF00}/-ehelper {FFFFFF}- вкл/выкл авто-открытие окна при запуске мероприятия")
        es_msg("{FFFF00}/et {FFFFFF}- тестовый режим: /b вместо /ao, в банк уходит 1$")
        es_msg("{FFFF00}/esc {FFFFFF}- сбросить сессию (сканы, игроки, окно помощника)")
        es_msg("{FFFF00}/-esr {FFFFFF}- скопировать ссылку CRM в буфер обмена")
        es_msg("{FFFF00}/enet {FFFFFF}- окно сетевых запросов текущей сессии")
        es_msg("{FFFF00}/esdb {FFFFFF}- вкл/выкл подробные логи (отладка)")
    end)

    DC.raw_register("enet", function()
        DC.net_open[0] = not DC.net_open[0]
    end)

    DC.raw_register("esdb", function()
        DC.DEBUG = not DC.DEBUG
        DC.debug_save()
        DC.trace("WARNING: debug mode = " .. tostring(DC.DEBUG))
        es_msg("Отладка " .. (DC.DEBUG and "{FFFF00}ВКЛЮЧЕНА" or "{FFFF00}ВЫКЛЮЧЕНА") .. "{FFFFFF} (сетевые логи применятся после перезапуска скрипта).")
    end)

    sampRegisterChatCommand("esc", function()
        DC.session_reset()
    end)

    sampRegisterChatCommand("et", function()
        DC.test_mode = not DC.test_mode
        DC.trace("test mode = " .. tostring(DC.test_mode))
        if DC.test_mode then
            es_msg("Тестовый режим {FFFF00}ВКЛЮЧЁН{FFFFFF}: вместо /ao пишется /b, в банк уходит {FFFF00}1${FFFFFF}.", "FFAA00")
        else
            es_msg("Тестовый режим {FFFF00}ВЫКЛЮЧЕН{FFFFFF}: /ao и полная сумма награды.")
        end
    end)

    sampRegisterChatCommand("esreset", function()
        os.remove(SCREENS_CACHE_FILE)
        screens_root_folder = nil
        es_msg("Кеш папки со скриншотами сброшен. Открываю окно для повторной настройки...")
        resolve_screens_root(function(path)
            screens_root_folder = path
        end)
    end)

    while true do
        ES_REAL_WAIT(0)
        local ok, err = pcall(DC.sched_step)
        if not ok then print('[EventScan] sched error: ' .. tostring(err)) end
    end
end