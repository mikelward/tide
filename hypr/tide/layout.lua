-- tide tiling for Hyprland 0.55+ (SPEC.md §6).
--
-- Registers one Lua layout, `lua:tide`, that keeps a mode per
-- workspace (tile, threecol, twocol, monocle) and applies the single-window
-- rule in every mode. Hyprland's own window order is the truth, so its swap
-- and move dispatchers keep working; the layout records that order so the
-- keybind helpers below can find the master and the neighbors.
--
-- Usage, from hyprland.lua:
--
--   local qs = dofile(os.getenv("HOME") .. "/.config/hypr/tide/layout.lua")
--   qs.setup({})   -- or override M.defaults' keys, which the settings
--                  -- panel and the bar don't see; layouts.json's they do
--   hl.config({ general = { layout = "lua:tide" } })
--   hl.bind("SUPER + period", qs.cycle_next)
--
-- The settings panel's Layouts page (SPEC.md §16) writes its settings to
-- ~/.config/hypr/tide-layouts.lua, a Lua table in setup()'s option names,
-- which setup() reads over its own options and `tide_layout.reload()`
-- (through `hyprctl eval`) reads again.
--
-- The helpers dispatch `layoutmsg`s and then announce the new mode on the
-- IPC socket as `custom>>tide-layout>>WORKSPACE,MODE`, which the bar
-- follows. A workspace becoming active announces its mode too, so a bar
-- that started after a mode changed learns it. They announce from a keybind
-- or an event rather than from inside the layout callback, so no dispatch
-- ever runs inside a layout callback.

-- geometry.lua sits beside this file. If the debug library isn't loaded,
-- fall back to where `make install` puts both.
local here = debug and debug.getinfo(1, "S").source:match("^@(.*/)")
    or (os.getenv("HOME") or "") .. "/.config/hypr/tide/"
local geometry = dofile(here .. "geometry.lua")

local M = { geometry = geometry }

M.defaults = {
    -- Work-area aspect ratio (width / height) at and above which a new
    -- workspace starts in the ultrawide mode below instead of the normal
    -- one. The work area excludes the bar: a 3440x1440 monitor gives about
    -- 2.45, 16:9 about 1.84.
    ultrawide_aspect = 2.1,
    -- The mode a new workspace starts in, by its monitor's aspect.
    default_mode = { normal = "tile", ultrawide = "threecol" },
    -- The single-window rule: a lone window's width by work-area aspect.
    single = {
        { min_aspect = 2.1, width = 0.8 },
        { min_aspect = 3.2, width = 0.6 },
    },
    modes = {
        tile = { mfact = 0.55, nmaster = 1 },
        threecol = { mfact = 0.5, nmaster = 1 },
        twocol = { mfact = 0.72, nmaster = 2 },
        monocle = {},
    },
    -- What Super+. and Super+, cycle through; monocle has its own toggle.
    cycle = { "tile", "threecol", "twocol" },
    mfact_step = 0.025,
}

local function copy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = copy(v)
    end
    return out
end

local function is_list(t)
    return t[1] ~= nil
end

-- Objects merge key by key; lists (the single rules, the cycle) are
-- replaced whole, the same rule as the .local config files (SPEC.md §16.1).
-- Whether a key holds a list is decided by the default as well as the
-- override, since an empty override (`single = {}`) looks like neither.
local function merge(base, over)
    local out = copy(base)
    for k, v in pairs(over or {}) do
        if type(v) == "table" and type(out[k]) == "table" and not is_list(out[k]) and not is_list(v) then
            out[k] = merge(out[k], v)
        else
            out[k] = copy(v)
        end
    end
    return out
end

local config = copy(M.defaults)
local workspaces = {}

local function index_of(list, value)
    for i, v in ipairs(list) do
        if v == value then
            return i
        end
    end
end

-- Field reads on Hyprland objects can fail for windows that are going away;
-- a failed read is treated as absent.
local function field(obj, key)
    if obj == nil then
        return nil
    end
    local ok, v = pcall(function()
        return obj[key]
    end)
    if ok then
        return v
    end
end

local function active_workspace_id()
    local ok, ws = pcall(hl.get_active_workspace)
    return ok and field(ws, "id") or nil
end

-- The workspace a layout call is for, as named by its windows. Only a
-- layoutmsg may fall back to the active workspace: it comes from a keybind
-- on the focused monitor. A relayout can be for any monitor, so a guess
-- there would overwrite another workspace's state.
local function workspace_id(ctx, fallback_to_active)
    for _, t in ipairs(ctx.targets) do
        local id = field(field(field(t, "window"), "workspace"), "id")
        if id ~= nil then
            return id
        end
    end
    if fallback_to_active then
        return active_workspace_id()
    end
end

local function default_mode(area)
    local aspect = area and area.h > 0 and area.w / area.h or 0
    return aspect >= config.ultrawide_aspect and config.default_mode.ultrawide or config.default_mode.normal
end

local function state_for(id, area)
    local st = workspaces[id]
    if not st then
        st = {
            mode = default_mode(area),
            opts = copy(config.modes),
            order = {},
        }
        workspaces[id] = st
    end
    return st
end

local function recalculate(ctx)
    local n = #ctx.targets
    if n == 0 then
        return
    end
    -- When no window names its workspace (they're all going away), place
    -- them in the default mode for the area and touch no stored state. A
    -- stale order is harmless: the helpers act only when the focused window
    -- is in it, and the next recalculate with windows replaces it.
    local id = workspace_id(ctx, false)
    if id == nil then
        local mode = default_mode(ctx.area)
        local boxes = geometry.arrange(mode, ctx.area, n, config.modes[mode], config.single)
        for i, t in ipairs(ctx.targets) do
            t:place(boxes[i])
        end
        return
    end
    local st = state_for(id, ctx.area)
    st.order = {}
    local boxes = geometry.arrange(st.mode, ctx.area, n, st.opts[st.mode], config.single)
    for i, t in ipairs(ctx.targets) do
        t:place(boxes[i])
        -- Append rather than index, so a window whose address can't be read
        -- (it's going away) leaves no hole for the helpers to trip on.
        local address = field(field(t, "window"), "address")
        if address ~= nil then
            st.order[#st.order + 1] = address
        end
    end
end

-- A mode the cycle doesn't list (a workspace that started in threecol under
-- `cycle = { "tile", "twocol" }`, or in monocle, with no mode before it)
-- sits before its first entry for next and after its last for prev, so one
-- press lands on an end of the cycle.
local function cycle(st, delta)
    local list = config.cycle
    local from = st.mode == "monocle" and st.previous or st.mode
    local i = index_of(list, from)
    if not i then
        return delta > 0 and list[1] or list[#list]
    end
    return list[((i - 1 + delta) % #list) + 1]
end

local function set_mode(st, mode)
    if mode ~= "monocle" then
        st.previous = nil
    elseif st.mode ~= "monocle" then
        st.previous = st.mode
    end
    st.mode = mode
end

-- `layoutmsg` commands:
--   mode <tile|threecol|twocol|monocle>, next, prev, monocle (toggle),
--   mfact <+d|-d|value>, addmaster, removemaster, reset, and refresh, which
--   changes nothing so the workspace is laid out again
local function layout_msg(ctx, msg)
    local id = workspace_id(ctx, true)
    if id == nil then
        return "tide: no workspace"
    end
    local st = state_for(id, ctx.area)
    local cmd, arg = msg:match("^%s*(%S+)%s*(.-)%s*$")
    local o = st.opts[st.mode]

    if cmd == "mode" then
        if not index_of(geometry.modes, arg) then
            return "tide: unknown mode '" .. tostring(arg) .. "'"
        end
        set_mode(st, arg)
    elseif cmd == "next" or cmd == "prev" then
        set_mode(st, cycle(st, cmd == "next" and 1 or -1))
    elseif cmd == "monocle" then
        set_mode(st, st.mode == "monocle" and (st.previous or config.cycle[1]) or "monocle")
    elseif cmd == "mfact" then
        if o.mfact == nil then
            return true
        end
        local sign, num = arg:match("^([+-]?)([%d.]+)$")
        num = tonumber(num)
        if not num then
            return "tide: mfact expects +d, -d or a value"
        end
        local v = sign == "+" and o.mfact + num or sign == "-" and o.mfact - num or num
        o.mfact = geometry.clamp(v, 0.1, 0.9)
    elseif cmd == "addmaster" or cmd == "removemaster" then
        if o.nmaster == nil then
            return true
        end
        local floor = st.mode == "tile" and 0 or 1
        o.nmaster = math.max(floor, o.nmaster + (cmd == "addmaster" and 1 or -1))
    elseif cmd == "reset" then
        st.opts[st.mode] = copy(config.modes[st.mode])
    elseif cmd == "refresh" then
        return true
    else
        return "tide: expected mode, next, prev, monocle, mfact, addmaster, removemaster, reset or refresh"
    end
    return true
end

-- The current mode of workspace `id`, or of the active one.
function M.mode(id)
    local st = workspaces[id or active_workspace_id()]
    return st and st.mode or nil
end

-- The tiled windows of workspace `id` in layout order, as addresses.
function M.order(id)
    local st = workspaces[id or active_workspace_id()]
    return st and copy(st.order) or {}
end

-- Announce workspace `id`'s mode, or the active one's. A workspace the
-- layout hasn't laid out yet has no mode to announce.
local function announce(id)
    id = id or active_workspace_id()
    local mode = M.mode(id)
    if id ~= nil and mode then
        hl.dispatch(hl.dsp.event("tide-layout>>" .. tostring(id) .. "," .. mode))
    end
end

local function msg(text)
    return function()
        hl.dispatch(hl.dsp.layout(text))
        announce()
    end
end

M.cycle_next = msg("next")
M.cycle_prev = msg("prev")
M.toggle_monocle = msg("monocle")
M.grow = function()
    msg("mfact +" .. config.mfact_step)()
end
M.shrink = function()
    msg("mfact -" .. config.mfact_step)()
end
M.add_master = msg("addmaster")
M.remove_master = msg("removemaster")
function M.set_mode(mode)
    msg("mode " .. mode)()
end

local function active_address()
    local ok, w = pcall(hl.get_active_window)
    return ok and field(w, "address") or nil
end

local function selector(address)
    return "address:" .. address
end

-- Super+Return: make the focused window the master. If it already is, swap
-- it with the first stack window instead, as dwm's zoom does.
function M.swap_with_master()
    local order, me = M.order(), active_address()
    local i = me and index_of(order, me)
    if not i or #order < 2 then
        return
    end
    local other = i == 1 and order[2] or order[1]
    hl.dispatch(hl.dsp.window.swap({ target = selector(other) }))
end

-- Super+J / Super+K: focus the next / previous window in layout order.
function M.focus(delta)
    local order, me = M.order(), active_address()
    local i = me and index_of(order, me)
    if not i or #order < 2 then
        return
    end
    local j = ((i - 1 + delta) % #order) + 1
    hl.dispatch(hl.dsp.focus({ window = selector(order[j]) }))
end

-- Super+Shift+J / Super+Shift+K: move the focused window down / up the order.
function M.move(delta)
    local order, me = M.order(), active_address()
    local i = me and index_of(order, me)
    local j = i and i + delta
    if not j or j < 1 or j > #order then
        return
    end
    hl.dispatch(hl.dsp.window.swap({ target = selector(order[j]) }))
end

-- The options setup() accepts, as a schema. Every key, type and range is
-- here, so validation is one walk over the merged config: an unknown key
-- (a typo) or a list with holes is an error, not silently ignored.
local function number(lo, hi, whole)
    return { kind = "number", lo = lo, hi = hi, whole = whole }
end
-- `required` makes every field mandatory, for records that have no
-- defaults to fall back on (a single-window rule).
local function record(fields, required)
    return { kind = "record", fields = fields, required = required }
end
-- `unique` rejects repeats: a mode listed twice in the cycle would make
-- next/prev loop back before reaching the entries after it.
local function list(item, min, unique)
    return { kind = "list", item = item, min = min or 0, unique = unique }
end

-- Modes the cycle may list. Monocle has its own toggle, and entering it from
-- the cycle would leave next/prev computing from the mode before it forever.
local cycle_modes = { tile = true, threecol = true, twocol = true }
-- Modes a workspace may start in: any of them.
local all_modes = { tile = true, threecol = true, twocol = true, monocle = true }

-- `min_masters` matches removemaster's floor: tile can go to plain rows,
-- the column modes always keep a master.
local function mode_opts(min_masters)
    if not min_masters then
        return record({})
    end
    return record({ mfact = number(0.1, 0.9), nmaster = number(min_masters, 100, true) })
end

local schema = record({
    ultrawide_aspect = number(0.1, 100),
    default_mode = record({ normal = { kind = "start" }, ultrawide = { kind = "start" } }),
    single = list(record({ min_aspect = number(0, 100), width = number(0.1, 1) }, true)),
    modes = record({
        tile = mode_opts(0),
        threecol = mode_opts(1),
        twocol = mode_opts(1),
        monocle = mode_opts(nil),
    }),
    cycle = list({ kind = "mode" }, 1, true),
    mfact_step = number(0.001, 0.5),
})

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

-- Returns an error message for the first problem in `v` at `path`, or nil.
local function check(v, sch, path)
    if sch.kind == "number" then
        -- NaN fails every comparison, so it needs its own test.
        if type(v) ~= "number" or v ~= v or v < sch.lo or v > sch.hi or (sch.whole and v % 1 ~= 0) then
            local what = sch.whole and "a whole number" or "a number"
            return string.format("%s must be %s from %s to %s", path, what, sch.lo, sch.hi)
        end
    elseif sch.kind == "mode" then
        if not cycle_modes[v] then
            return path .. " must be tile, threecol or twocol, not " .. tostring(v)
        end
    elseif sch.kind == "start" then
        if not all_modes[v] then
            return path .. " must be tile, threecol, twocol or monocle, not " .. tostring(v)
        end
    elseif sch.kind == "record" then
        if type(v) ~= "table" then
            return path .. " must be a table"
        end
        for _, k in ipairs(sorted_keys(v)) do
            if not sch.fields[k] then
                return path .. "." .. tostring(k) .. " is not an option"
            end
        end
        for _, k in ipairs(sorted_keys(sch.fields)) do
            if v[k] == nil and sch.required then
                return path .. "." .. k .. " is required"
            end
            if v[k] ~= nil then
                local err = check(v[k], sch.fields[k], path .. "." .. k)
                if err then
                    return err
                end
            end
        end
    elseif sch.kind == "list" then
        if type(v) ~= "table" then
            return path .. " must be a list"
        end
        -- A list's keys must be exactly 1..n; a hole makes # and ipairs
        -- disagree about its length.
        local n = 0
        for k in pairs(v) do
            if math.type(k) ~= "integer" or k < 1 then
                return path .. " must be a list, not a table"
            end
            n = n + 1
        end
        for i = 1, n do
            if v[i] == nil then
                return path .. " has a hole at [" .. i .. "]"
            end
        end
        if n < sch.min then
            return path .. " must have at least " .. sch.min .. " entry"
        end
        local seen = {}
        for i = 1, n do
            local err = check(v[i], sch.item, path .. "[" .. i .. "]")
            if err then
                return err
            end
            if sch.unique then
                if seen[v[i]] then
                    return string.format("%s[%d] repeats %s from [%d]", path, i, tostring(v[i]), seen[v[i]])
                end
                seen[v[i]] = i
            end
        end
    end
end

-- Check a merged config, so a bad option is reported once, at load, rather
-- than as an error on some later keypress or relayout. Returns an error
-- message, or nil.
local function validate(c)
    local err = check(c, schema, "setup")
    return err and err:gsub("^setup%.", "") or nil
end

-- Where the Layouts page's settings are, as `$XDG_CONFIG_HOME/hypr`
-- (`~/.config/hypr` by default) has them. A field, so the tests can point
-- it elsewhere before setup().
do
    local config_home = os.getenv("XDG_CONFIG_HOME")
    if config_home == nil or config_home == "" then
        config_home = (os.getenv("HOME") or "") .. "/.config"
    end
    M.settings_file = config_home .. "/hypr/tide-layouts.lua"
end

-- The settings file's table: {} when there's none, else nil and why it
-- can't be used. It's data, so it runs with no globals.
local function read_settings(path)
    local f, open_err, code = io.open(path, "r")
    if not f then
        if code == 2 then -- ENOENT: nothing set
            return {}
        end
        return nil, "couldn't open " .. path .. ": " .. tostring(open_err)
    end
    local max = 64 * 1024
    local text, read_err = f:read(max + 1)
    f:close()
    if text == nil and read_err then
        return nil, "couldn't read " .. path .. ": " .. tostring(read_err)
    end
    text = text or ""
    if #text > max then
        return nil, path .. " is larger than " .. max .. " bytes"
    end
    local chunk, load_err = load(text, "@" .. path, "t", {})
    if not chunk then
        return nil, tostring(load_err)
    end
    local ok, value = pcall(chunk)
    if not ok then
        return nil, tostring(value)
    end
    if type(value) ~= "table" then
        return nil, path .. ": expected a table, not " .. type(value)
    end
    return value
end

-- setup()'s options, merged over the defaults; kept for reload().
local base = copy(M.defaults)

-- The config with the settings file over `base`, or nil and why not, which
-- names the file.
local function with_settings()
    local settings, err = read_settings(M.settings_file)
    if not settings then
        return nil, err
    end
    local c = merge(base, settings)
    err = validate(c)
    if err then
        return nil, M.settings_file .. ": " .. err
    end
    return c
end

-- Reads the settings file again and takes it, as the Layouts page asks
-- through `hyprctl eval 'tide_layout.reload()'`. Each workspace keeps its
-- mode and takes the new mfact and master counts, and the active one is
-- laid out again; the others are as they're next shown. A file that
-- can't be used is an error, which `hyprctl eval` answers with, and
-- changes nothing.
function M.reload()
    local c, err = with_settings()
    if not c then
        error("tide: " .. err, 0)
    end
    config = c
    for _, st in pairs(workspaces) do
        st.opts = copy(config.modes)
    end
    hl.dispatch(hl.dsp.layout("refresh"))
end

function M.setup(opts)
    local c = merge(M.defaults, opts)
    local err = validate(c)
    if err then
        error("tide.setup: " .. err, 2)
    end
    base = c
    -- A settings file that can't be used is reported, and the config goes
    -- ahead without it: it's tide's to write, and a bad one mustn't stop
    -- Hyprland's config loading.
    local with, settings_err = with_settings()
    if with then
        config = with
    else
        config = c
        hl.notification.create({ text = "tide layouts: " .. settings_err, duration = 15000, icon = "error" })
    end
    workspaces = {}
    hl.layout.register("tide", {
        recalculate = recalculate,
        layout_msg = layout_msg,
    })
    hl.on("workspace.active", function(ws)
        announce(field(ws, "id"))
    end)
    -- For the shell, which calls it through `hyprctl eval`.
    _G.tide_layout = { reload = M.reload }
    return M
end

return M
