-- tide tiling for Hyprland 0.55+ (SPEC.md §6).
--
-- Registers one Lua layout, `lua:tide`, that keeps a mode per
-- workspace (tile, threecol, twocol, monocle) and applies the single-window
-- rule in every mode. Hyprland adds each new window at the end of its own
-- order, and a Lua layout can't change that order, so the layout keeps its
-- own: it makes each swap Hyprland makes, so Hyprland's swap and move
-- dispatchers keep working, and it puts a window new to the workspace where
-- `new_window` says. The keybind helpers below use it to find the master
-- and the neighbors.
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
local direction = dofile(here .. "direction.lua")

local M = { geometry = geometry, direction = direction }

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
    -- Where a window new to a workspace's tiling goes in its order: "end"
    -- of the stack, "top" of it (just after the masters), "next" after the
    -- window that was focused, or "master". One moved here from another
    -- workspace, or tiled again after floating, counts as new.
    new_window = "end",
    mfact_step = 0.025,
    -- How far either side of a split edge a plain left-drag grabs it, in
    -- pixels (drag_press below); 0 turns edge dragging off.
    resize_grab = 4,
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
-- The window Super+Shift+Left or Right is moving onto another monitor, as
-- { address, ws, d, from }: where it lands in that workspace's order
-- (direction.landing) once its relayout sees it. Set by move_side, taken by
-- the next relayout of `ws` that has the window new to it.
local arriving

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

local function active_address()
    local ok, w = pcall(hl.get_active_window)
    return ok and field(w, "address") or nil
end

local function selector(address)
    return "address:" .. address
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
        -- `order` is the layout's order and `seen` Hyprland's, as of the
        -- last relayout; nil until the first.
        st = {
            mode = default_mode(area),
            opts = copy(config.modes),
            order = {},
        }
        workspaces[id] = st
    end
    return st
end

local function set_of(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

local function only(list, set)
    local out = {}
    for _, v in ipairs(list) do
        if set[v] then
            out[#out + 1] = v
        end
    end
    return out
end

-- Where `new_window` puts the first of the windows new to `order`. Asking
-- for the focused window is a query, not a dispatch, so it's safe here; a
-- new window isn't focused until after Hyprland lays it out.
local function insert_at(st, order)
    local rule = config.new_window
    if rule == "master" then
        return 1
    elseif rule == "top" then
        -- Monocle has no masters to go after, so its first window counts.
        local masters = st.opts[st.mode].nmaster or 1
        return math.min(masters, #order) + 1
    elseif rule == "next" then
        local me = active_address()
        local i = me and index_of(order, me)
        if i then
            return i + 1
        end
    end
    return #order + 1
end

-- The layout's order now that Hyprland's has gone from `st.seen` to `now`:
-- without the windows that left, with the swap Hyprland made made here too
-- (its swap and move dispatchers each make one, and each relayouts), and
-- with each new window where `new_window` says. A change that's more than
-- one swap takes Hyprland's order for the windows it already had.
-- `place_new`, if given, says where a new window goes instead, or nil.
local function follow(st, now, place_new)
    local here, before = set_of(now), set_of(st.seen)
    local order = only(st.order, here)
    local was, is = only(st.seen, here), only(now, before)
    local moved = {}
    for i = 1, #is do
        if is[i] ~= was[i] then
            moved[#moved + 1] = i
        end
    end
    local a, b = moved[1], moved[2]
    if #moved == 2 and is[a] == was[b] and is[b] == was[a] then
        local i, j = index_of(order, was[a]), index_of(order, was[b])
        order[i], order[j] = order[j], order[i]
    elseif #moved > 0 then
        order = is
    end
    local at
    for _, address in ipairs(now) do
        if not before[address] then
            local landing = place_new and place_new(order, address)
            if landing then
                table.insert(order, landing, address)
            else
                at = at and at + 1 or insert_at(st, order)
                table.insert(order, at, address)
            end
        end
    end
    return order
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
    -- A window whose address can't be read (it's going away) is left out
    -- of the order, so it leaves no hole for the helpers to trip on, and
    -- takes a place after the rest.
    local addresses, now = {}, {}
    for i, t in ipairs(ctx.targets) do
        addresses[i] = field(field(t, "window"), "address")
        if addresses[i] ~= nil then
            now[#now + 1] = addresses[i]
        end
    end
    -- The first relayout of a workspace, after a config load too, takes
    -- Hyprland's order as it is.
    local master = st.order[1]
    -- A window Super+Shift+Left or Right moved here lands at the edge it
    -- came in by. Seen anywhere else first, it went elsewhere, and later
    -- goes where new windows go.
    if arriving and arriving.ws ~= id and index_of(now, arriving.address) then
        arriving = nil
    end
    local function place_new(order, address)
        local a = arriving
        if not a or a.address ~= address or a.ws ~= id then
            return nil
        end
        arriving = nil
        local slots = geometry.arrange(st.mode, ctx.area, #order + 1, st.opts[st.mode], config.single)
        return direction.landing(slots, a.d, a.from)
    end
    st.order = st.seen and follow(st, now, place_new) or now
    st.seen = now
    -- Whatever made another window the master (Alt+Tab, a new window
    -- placed as the master, Super+Shift+K), the one it took over from is
    -- the one Alt+Tab on the master goes back to, if it's still here.
    if master and st.order[1] ~= master and index_of(st.order, master) then
        st.previous_master = master
    end
    local place = {}
    for i, address in ipairs(st.order) do
        place[address] = i
    end
    local spare = #st.order
    local boxes = geometry.arrange(st.mode, ctx.area, n, st.opts[st.mode], config.single)
    for i, t in ipairs(ctx.targets) do
        local p = addresses[i] and place[addresses[i]]
        if not p then
            spare = spare + 1
            p = spare
        end
        t:place(boxes[p])
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
        o.mfact = geometry.clamp(v, geometry.mfact_min, geometry.mfact_max)
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

-- Alt+Tab (SPEC.md §6.6): make the focused window the master. On the
-- master, swap it with the window that was master before it, so presses
-- go back and forth between two; once that window is gone, with the top of
-- the stack, as dwm's zoom does. Each workspace remembers its own, from any
-- change of master its relayouts see (recalculate).
function M.swap_with_master()
    local id = active_workspace_id()
    local st = workspaces[id]
    local order, me = M.order(id), active_address()
    local i = me and index_of(order, me)
    if not st or not i or #order < 2 then
        return
    end
    local other
    if i == 1 then
        local before = st.previous_master
        other = (before and before ~= me and index_of(order, before)) and before or order[2]
    else
        other = order[1]
    end
    -- The window leaving the master is the one to come back to.
    st.previous_master = order[1]
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

-- A window's box, from Hyprland's `at` and `size`, or nil.
local function box_of(w)
    local at, size = field(w, "at"), field(w, "size")
    if at and size and at.x and size.x then
        return { x = at.x, y = at.y, w = size.x, h = size.y }
    end
end

-- A monitor's box in layout coordinates: Hyprland gives its position in
-- those but its size in pixels, before scale and rotation.
local function monitor_box(m)
    local x, y, w, h = field(m, "x"), field(m, "y"), field(m, "width"), field(m, "height")
    if not (x and y and w and h) then
        return nil
    end
    local scale = tonumber(field(m, "scale")) or 1
    if scale <= 0 then
        scale = 1
    end
    -- Transforms 1, 3, 5 and 7 turn the output a quarter, swapping its sides.
    if (tonumber(field(m, "transform")) or 0) % 2 == 1 then
        w, h = h, w
    end
    return { x = x, y = y, w = w / scale, h = h / scale }
end

-- The monitors as direction.find takes them, with the tiles each shows in
-- layout order, plus the focused one's name and the focused window: nil if
-- Hyprland can't be read. A monitor showing a fullscreen window offers no
-- tiles, since they're behind it.
local function sides()
    local ok_mon, mons = pcall(hl.get_monitors)
    local ok_win, wins = pcall(hl.get_windows)
    if not (ok_mon and type(mons) == "table" and ok_win and type(wins) == "table") then
        return nil
    end
    local me = active_address()
    local by_ws, mine = {}, nil
    for _, w in ipairs(wins) do
        local address, ws, box = field(w, "address"), field(field(w, "workspace"), "id"), box_of(w)
        if address == me then
            mine = { address = address, ws = ws, box = box, floating = field(w, "floating") }
        end
        if field(w, "mapped") and not field(w, "hidden") and not field(w, "floating") and ws ~= nil and box then
            by_ws[ws] = by_ws[ws] or {}
            by_ws[ws][address] = box
        end
    end
    local list, focused = {}, nil
    for _, m in ipairs(mons) do
        local name, box = field(m, "name"), monitor_box(m)
        local ws = field(m, "active_special_workspace") or field(m, "active_workspace")
        local id = field(ws, "id")
        if name and box then
            local tiles = {}
            if id ~= nil and not field(ws, "has_fullscreen") then
                local boxes = by_ws[id] or {}
                -- Layout order, then any the layout hasn't placed yet.
                local listed = {}
                for _, address in ipairs(M.order(id)) do
                    if boxes[address] then
                        tiles[#tiles + 1] = { address = address, box = boxes[address] }
                        listed[address] = true
                    end
                end
                for _, w in ipairs(wins) do
                    local address = field(w, "address")
                    if address and boxes[address] and not listed[address] then
                        tiles[#tiles + 1] = { address = address, box = boxes[address] }
                        listed[address] = true
                    end
                end
            end
            -- A window moved to a monitor goes to its active workspace,
            -- whatever special one shows over it.
            local active = field(field(m, "active_workspace"), "id")
            list[#list + 1] = { name = name, box = box, ws = id, active = active, tiles = tiles }
            if field(m, "focused") then
                focused = list[#list]
            end
        end
    end
    -- The focused window's monitor is the one showing its workspace.
    local here = focused
    if mine and mine.ws ~= nil then
        for _, m in ipairs(list) do
            if m.ws == mine.ws then
                here = m
            end
        end
    end
    if not here then
        return nil
    end
    local from_tiles = {}
    for _, t in ipairs(here.tiles) do
        if not mine or t.address ~= mine.address then
            from_tiles[#from_tiles + 1] = t
        end
    end
    here.tiles = from_tiles
    return list, here, mine
end

-- Super+Left / Super+Right (d = -1 / 1): focus the window that way, going
-- on at the monitor's edge to the nearest window on the next monitor that
-- way, or to that monitor itself if it shows none. Past the last monitor,
-- nothing.
function M.focus_side(d)
    local list, here, mine = sides()
    if not list then
        return
    end
    local from = mine and mine.box or here.box
    local tile, mon = direction.find(from, here.name, list, d)
    if tile then
        hl.dispatch(hl.dsp.focus({ window = selector(tile.address) }))
    elseif mon then
        hl.dispatch(hl.dsp.focus({ monitor = mon.name }))
    end
end

-- Super+Shift+Left / Super+Shift+Right: move the focused tiled window the
-- same way. On its monitor it swaps with the window focus_side would pick;
-- at the edge it goes onto the next monitor, joining the workspace there
-- at the edge it came in by, and keeps focus. Past the last monitor, or for
-- a floating window, nothing.
function M.move_side(d)
    arriving = nil
    local list, here, mine = sides()
    if not list or not mine or not mine.box or mine.floating or mine.ws == nil then
        return
    end
    local tile, mon = direction.find(mine.box, here.name, list, d)
    if not mon then
        return
    end
    if mon == here then
        hl.dispatch(hl.dsp.window.swap({ target = selector(tile.address) }))
    elseif mon.active ~= nil then
        arriving = { address = mine.address, ws = mon.active, d = d, from = mine.box }
        hl.dispatch(hl.dsp.window.move({ monitor = mon.name, follow = true }))
    end
end

-- Dragging a split edge with the pointer, no modifier held (SPEC.md §6.6).
-- Hyprland 0.56.2 hands a tiled window's border drag to a Lua layout as
-- nothing but a relayout (`CLuaTiledAlgorithm::resizeTarget` drops the
-- delta), and with no gaps the edge between two tiles is inside one of
-- them, so its own resize_on_border never starts there. So a plain
-- left-button bind asks drag_press whether the press is on an edge: if
-- not, the click goes on to the window as usual; if so, it's taken, and a
-- timer follows the pointer with mfact layoutmsgs until drag_release.
-- Lua sees no pointer motion, hence the timer, which runs only while a
-- drag does. Both run from a bind or a timer, never a layout callback.
local PASS = { pass_event = true }
local DRAG_TICK_MS = 16
local drag, drag_timer
-- Whether one of the shell's popovers or menus is open. Each is an
-- xdg_popup of the bar, which Hyprland 0.56.2's Lua can't see (a layer's
-- x, y, w and h are its own surface's alone), so the shell says
-- (set_popups_open), and while one is open every press passes on.
local popups_open = false

-- From the shell, through `hyprctl eval`, whenever its first popover opens
-- or its last closes, and again as it starts and after a config load.
function M.set_popups_open(open)
    if type(open) ~= "boolean" then
        error("tide: set_popups_open expects true or false, not " .. tostring(open), 0)
    end
    popups_open = open
end

-- A config value, or nil if it can't be read.
local function config_value(key)
    local ok, v = pcall(hl.get_config, key)
    if ok then
        return v
    end
end

local function truthy(v)
    return v == true or (type(v) == "number" and v ~= 0)
end

-- Whether something above the tiles takes a press at (x, y): a floating
-- window of `windows`, with the ring outside it where Hyprland starts its
-- own border resize, or a top or overlay layer (a notification, the
-- switcher); the shell's popovers are popups of a layer, which
-- set_popups_open covers. If the layers can't be read, the answer is yes,
-- so the click goes where it would have without tide.
local function covered(windows, x, y)
    local ring = 0
    if truthy(config_value("general:resize_on_border")) then
        ring = (tonumber(config_value("general:border_size")) or 0)
            + (tonumber(config_value("general:extend_border_grab_area")) or 0)
    end
    for _, w in ipairs(windows) do
        local at, size = field(w, "at"), field(w, "size")
        if field(w, "floating") and field(w, "visible") and at and size then
            if geometry.contains({ x = at.x, y = at.y, w = size.x, h = size.y }, x, y, ring) then
                return true
            end
        end
    end
    local ok_layers, layers = pcall(hl.get_layers)
    if not ok_layers or type(layers) ~= "table" then
        return true
    end
    for _, l in ipairs(layers) do
        local level, lx, ly, lw, lh = field(l, "layer"), field(l, "x"), field(l, "y"), field(l, "w"), field(l, "h")
        -- zwlr_layer_shell_v1: 2 is top, 3 overlay; below them are the
        -- wallpaper and the like, under the windows.
        if field(l, "mapped") and level and level >= 2 and lx and lw then
            if geometry.contains({ x = lx, y = ly, w = lw, h = lh }, x, y) then
                return true
            end
        end
    end
    return false
end

-- The boxes of workspace `id`'s tiles as `windows` has them now: its
-- mapped, tiled windows, less those hidden behind another in a group. `at`
-- and `size` are where Hyprland is putting each, not where an animation
-- has got to, and with no gaps or borders they're the boxes the layout
-- placed. Reading them on every press, rather than keeping what the last
-- recalculate placed, leaves nothing to go stale: Hyprland calls no
-- recalculate for a workspace its last tiled windows leave.
local function tiles(windows, id)
    local boxes = {}
    for _, w in ipairs(windows) do
        local at, size = field(w, "at"), field(w, "size")
        if field(w, "mapped") and not field(w, "hidden") and not field(w, "floating")
            and field(field(w, "workspace"), "id") == id and at and size then
            boxes[#boxes + 1] = { x = at.x, y = at.y, w = size.x, h = size.y }
        end
    end
    return boxes
end

local function stop_drag()
    drag = nil
    if drag_timer then
        drag_timer:set_enabled(false)
    end
end

-- One step of a drag: the mfact that puts the edge under the pointer, sent
-- as a layoutmsg when it changes. A layoutmsg goes to the focused
-- monitor's workspace, so a step is skipped while that's not the dragged
-- one, and a mode change ends the drag.
local function drag_step()
    if not drag then
        stop_drag()
        return
    end
    local st = workspaces[drag.ws]
    if not st or st.mode ~= drag.mode then
        stop_drag()
        return
    end
    if active_workspace_id() ~= drag.ws then
        return
    end
    local ok, pos = pcall(hl.get_cursor_pos)
    if not ok or not pos then
        return -- no pointer to follow this step; the next one tries again
    end
    local v = geometry.drag_mfact(drag.edge, drag.area, pos.x - drag.offset)
    v = v and tonumber(string.format("%.4f", v))
    if v and v ~= drag.mfact then
        drag.mfact = v
        hl.dispatch(hl.dsp.layout(string.format("mfact %.4f", v)))
    end
end

-- The left button's press, unmodified: starts a drag if it's on a split
-- edge of the focused monitor's tiles with nothing above them there, and
-- otherwise passes the click on, which also leaves floating windows'
-- edges to Hyprland's resize_on_border.
function M.drag_press()
    local grab = config.resize_grab
    if grab <= 0 or popups_open then
        return PASS
    end
    local ok_pos, pos = pcall(hl.get_cursor_pos)
    local ok_mon, mon = pcall(hl.get_monitor_at_cursor)
    if not (ok_pos and pos and ok_mon and mon) then
        return PASS
    end
    if not field(mon, "focused") or field(mon, "active_special_workspace") then
        return PASS
    end
    local ws = field(mon, "active_workspace")
    local id = field(ws, "id")
    local st = id ~= nil and workspaces[id]
    if not st or field(ws, "has_fullscreen") then
        return PASS
    end
    -- One read of the windows, for where the edge is and what's above it.
    -- If they can't be read, the click goes where it would without tide.
    local ok_win, windows = pcall(hl.get_windows)
    if not ok_win or type(windows) ~= "table" then
        return PASS
    end
    local boxes = tiles(windows, id)
    local area = geometry.bounds(boxes)
    if not area then
        return PASS
    end
    local o = st.opts[st.mode]
    local edge = geometry.edge_at(geometry.split_edges(st.mode, area, #boxes, o), area, pos.x, pos.y, grab)
    if not edge or covered(windows, pos.x, pos.y) then
        return PASS
    end
    -- The edge keeps its offset from the pointer, so it doesn't jump to it.
    -- The area is the press's: an mfact change moves the edge, not the area.
    drag = { ws = id, mode = st.mode, edge = edge, area = area, offset = pos.x - edge.x, mfact = o.mfact }
    if drag_timer then
        drag_timer:set_enabled(true)
    else
        drag_timer = hl.timer(drag_step, { timeout = DRAG_TICK_MS, type = "repeat" })
    end
end

-- The left button's release, whatever the modifiers: the last step, then
-- the drag ends. Any other release finds no drag and does nothing.
function M.drag_release()
    if drag then
        drag_step()
        stop_drag()
    end
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
local new_window_rules = { ["end"] = true, top = true, next = true, master = true }

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
    resize_grab = number(0, 32, true),
    new_window = { kind = "new_window" },
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
    elseif sch.kind == "new_window" then
        if not new_window_rules[v] then
            return path .. " must be end, top, next or master, not " .. tostring(v)
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
    -- A config load forgets the shell's popovers until it says again.
    drag, drag_timer, popups_open, arriving = nil, nil, false, nil
    hl.layout.register("tide", {
        recalculate = recalculate,
        layout_msg = layout_msg,
    })
    hl.on("workspace.active", function(ws)
        announce(field(ws, "id"))
    end)
    -- For the shell, which calls it through `hyprctl eval`.
    _G.tide_layout = { reload = M.reload, set_popups_open = M.set_popups_open }
    return M
end

return M
