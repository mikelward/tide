-- tide's pinned apps for Hyprland 0.56.2+ (SPEC.md §6.5).
--
-- A workspace's pinned apps (`pinnedApps` in workspaces.json's
-- `workspaceSettings`) stay open there: tide's close keys leave a window of
-- one open while it's on that workspace, and a notification says why. The
-- window's own close button still closes it; nothing here can see that.
--
-- Usage, from hyprland.lua, which reads tide-workspaces.lua's `pinned` list
-- (the shell writes it, workspacenames.mjs's pinnedMatchers) and hands it on
-- at each load and conf_workspaces.reload():
--
--   local pinned = dofile(os.getenv("HOME") .. "/.config/hypr/tide/pinned.lua")
--   pinned.set(value.pinned)
--   hl.bind("SUPER + BackSpace", pinned.close)
--   for _, keys in ipairs(pinned.shortcuts) do
--       hl.bind(keys, pinned.shortcut)
--   end
--
-- close() closes the focused window, as hl.dsp.window.close() does, unless
-- it's pinned. shortcut(), bound to an app's own close and quit keys, passes
-- the key on to the focused window by returning { pass_event = true }, unless
-- that window is pinned: then the key goes nowhere, so the app never sees it.
-- Hyprland 0.56.2 reads a Lua bind's result as a dispatch result
-- (dispatchResultFromLua, LuaBindingsRegistration.cpp), and its key handler
-- sends a key whose bind passes the event on to the focused window, its
-- release too (CKeybindManager::onKeyEvent and handleKeybinds). A bind can't
-- be conditional on the window, so this is how a key reaches every window
-- but a pinned one.
--
-- A window matches as the shell matches it (workspacenames.mjs's
-- appMatchers and isHomeApp): a class ignoring case, a bare name matching
-- the last part of a qualified one, and a site matching its Chrome and
-- Chromium `--app` windows, its subdomains' too, in any profile. A
-- monitor's part of a workspace (NAME@OUT, span.lua) is that workspace, and
-- a minimized window, on a special workspace, is on none. Workspace names
-- match ignoring case, ASCII case only: Lua's lower() knows no other.

local M = {}

-- The keys an app closes a window or quits on, which shortcut() is bound to:
-- browsers' close tab and close window, the common quit, and X11's close.
M.shortcuts = { "CTRL + W", "CTRL + SHIFT + W", "CTRL + Q", "ALT + F4" }

-- A key bind's result that sends the key on to the focused window.
local PASS = { pass_event = true }

-- { { workspace = NAME, classes = { APP, ... }, sites = { HOST, ... } } }
local pinned = {}

-- Field reads on Hyprland objects can fail for windows that are going away;
-- a failed read is absent, as in focus.lua.
local function field(obj, key)
    if obj == nil then
        return nil
    end
    local ok, v = pcall(function()
        return obj[key]
    end)
    return ok and v or nil
end

-- An app id as the shell normalizes one (normalizeAppId): trimmed,
-- lowercase and without a `.desktop` suffix.
local function normalize(id)
    if type(id) ~= "string" then
        return nil
    end
    local n = (id:match("^%s*(.-)%s*$"):lower():gsub("%.desktop$", ""))
    return n ~= "" and n or nil
end

-- The workspace a Hyprland workspace's name is a part of, or nil for a
-- special one: NAME@OUT is NAME (span.lua, span.mjs's workspaceOf).
local function workspace_of(name)
    if type(name) ~= "string" or name == "" or name:find("^special:") then
        return nil
    end
    return name:match("^(.+)@[^@]+$") or name
end

-- Whether normalized class c is app's: the same, or, for a bare app, the
-- last part of a qualified class.
local function class_matches(c, app)
    if c == app then
        return true
    end
    if app:find(".", 1, true) then
        return false
    end
    return c:sub(-(#app + 1)) == "." .. app
end

-- The site a Chrome or Chromium `--app` window's normalized class is of,
-- or nil: chrome-mail.google.com__-default is mail.google.com.
local function site_of(c)
    local rest = c:match("^chrome%-(.+)$") or c:match("^chromium%-(.+)$")
    if not rest then
        return nil
    end
    local host, tail = rest:match("^([^_]*)_(.*)$")
    if not host or not tail:find("%-[^%-]+$") then
        return nil
    end
    return host
end

local function site_matches(host, site)
    return host == site or host:sub(-(#site + 1)) == "." .. site
end

-- A list of non-empty strings, normalized, or an error naming it.
local function strings(v, i, key)
    if v == nil then
        return {}
    end
    if type(v) ~= "table" then
        error(("tide pinned.set: entry %d's %s should be a list, not %s"):format(i, key, type(v)), 3)
    end
    local count = 0
    for _ in pairs(v) do
        count = count + 1
    end
    local out = {}
    for j = 1, count do
        local s = normalize(v[j])
        if not s then
            error(("tide pinned.set: entry %d's %s should list names, with no gaps; %d is %s"):format(i, key, j, tostring(v[j])), 3)
        end
        out[j] = s
    end
    return out
end

-- Takes the pinned apps: a list of { workspace, classes, sites }, as
-- tide-workspaces.lua's `pinned` has them. One that's wrong raises an error
-- naming what, and the ones before stay.
function M.set(list)
    if list == nil then
        list = {}
    end
    if type(list) ~= "table" then
        error("tide pinned.set: expected a list of workspaces' pinned apps, not " .. type(list), 2)
    end
    local count = 0
    for _ in pairs(list) do
        count = count + 1
    end
    local out = {}
    for i = 1, count do
        local p = list[i]
        if type(p) ~= "table" then
            error(("tide pinned.set: entry %d should be a table, not %s"):format(i, type(p)), 2)
        end
        if type(p.workspace) ~= "string" or not p.workspace:find("%S") then
            error(("tide pinned.set: entry %d should name its workspace"):format(i), 2)
        end
        out[i] = { workspace = p.workspace, classes = strings(p.classes, i, "classes"), sites = strings(p.sites, i, "sites") }
    end
    pinned = out
end

-- The workspace window w is pinned on, as Hyprland names it, or nil.
function M.pinned_on(w)
    local ws = workspace_of(field(field(w, "workspace"), "name"))
    local c = normalize(field(w, "class"))
    if not ws or not c then
        return nil
    end
    local host = site_of(c)
    for _, p in ipairs(pinned) do
        if p.workspace:lower() == ws:lower() then
            for _, app in ipairs(p.classes) do
                if class_matches(c, app) then
                    return ws
                end
            end
            for _, site in ipairs(p.sites) do
                if host and site_matches(host, site) then
                    return ws
                end
            end
        end
    end
    return nil
end

local function quoted(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Says a close was refused, as the shell's name prompt says it
-- (workspacenames.mjs's pinnedNotice). A field so a config can change it.
function M.notify(workspace)
    hl.exec_cmd("notify-send --app-name=tide " .. quoted("Pinned window") .. " "
        .. quoted("It's pinned on " .. workspace .. ", so it stays open."))
end

-- The workspace the focused window is pinned on, or nil. A read that
-- fails is reported, and the key does what it would with nothing pinned.
local function focused_pin()
    local ok, result = pcall(function()
        local w = hl.get_active_window()
        return w and M.pinned_on(w) or nil
    end)
    if not ok then
        hl.notification.create({ text = "tide pinned: couldn't read the focused window: " .. tostring(result), duration = 5000, icon = "error" })
        return nil
    end
    return result
end

-- Super+Backspace: closes the focused window, politely, unless it's pinned.
function M.close()
    local ws = focused_pin()
    if ws then
        M.notify(ws)
        return nil
    end
    hl.dispatch(hl.dsp.window.close())
    return nil
end

-- An app's own close or quit key: on to the focused window, unless it's
-- pinned.
function M.shortcut()
    local ws = focused_pin()
    if ws then
        M.notify(ws)
        return nil
    end
    return PASS
end

return M
