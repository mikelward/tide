-- Tests for geometry.lua and layout.lua. Plain Lua (5.4 or 5.5), no
-- dependencies: `lua hypr/tide/layout_test.lua` from the repo root.
-- layout.lua runs against a stub of the Hyprland `hl` API that records what
-- it registers and dispatches.

local dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local geometry = dofile(dir .. "geometry.lua")

local failures, passed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failures = failures + 1
        io.stderr:write("FAIL " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function eq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value", tostring(got), tostring(want)), 2)
    end
end

local function box_eq(got, want, what)
    for _, k in ipairs({ "x", "y", "w", "h" }) do
        if got == nil or got[k] ~= want[k] then
            local g = got and string.format("{%s,%s,%s,%s}", got.x, got.y, got.w, got.h) or "nil"
            error(string.format("%s: got %s, want {%s,%s,%s,%s}", what or "box", g, want.x, want.y, want.w, want.h), 2)
        end
    end
end

-- The boxes cover `area` exactly: all inside it, no two overlapping, and
-- their areas summing to its area.
local function covers(area, boxes, what)
    local sum = 0
    for i, b in ipairs(boxes) do
        if b.w <= 0 or b.h <= 0 then
            error(string.format("%s: box %d is empty", what, i), 2)
        end
        if b.x < area.x or b.y < area.y or b.x + b.w > area.x + area.w or b.y + b.h > area.y + area.h then
            error(string.format("%s: box %d leaves the area", what, i), 2)
        end
        for j = i + 1, #boxes do
            local c = boxes[j]
            if b.x < c.x + c.w and c.x < b.x + b.w and b.y < c.y + c.h and c.y < b.y + b.h then
                error(string.format("%s: boxes %d and %d overlap", what, i, j), 2)
            end
        end
        sum = sum + b.w * b.h
    end
    if sum ~= area.w * area.h then
        error(string.format("%s: boxes cover %d px, area is %d", what, sum, area.w * area.h), 2)
    end
end

-- Work areas below a 34 px bar.
local UW = { x = 0, y = 34, w = 3440, h = 1406 } -- 3440x1440, aspect ~2.45
local HD = { x = 0, y = 34, w = 1920, h = 1046 } -- 1920x1080, aspect ~1.84
local SUW = { x = 0, y = 34, w = 5120, h = 1406 } -- 5120x1440, aspect ~3.64
local RULES = { { min_aspect = 2.1, width = 0.8 }, { min_aspect = 3.2, width = 0.6 } }

-- geometry ------------------------------------------------------------------

test("tile puts the master left at mfact and stacks the rest", function()
    local b = geometry.tile(UW, 4, { mfact = 0.55, nmaster = 1 })
    box_eq(b[1], { x = 0, y = 34, w = 1892, h = 1406 }, "master")
    box_eq(b[2], { x = 1892, y = 34, w = 1548, h = 469 }, "stack 1")
    box_eq(b[3], { x = 1892, y = 503, w = 1548, h = 468 }, "stack 2")
    box_eq(b[4], { x = 1892, y = 971, w = 1548, h = 469 }, "stack 3")
    covers(UW, b, "tile")
end)

test("tile with nmaster 0 or nmaster >= n is plain rows", function()
    covers(HD, geometry.tile(HD, 3, { mfact = 0.55, nmaster = 0 }), "nmaster 0")
    local b = geometry.tile(HD, 2, { mfact = 0.55, nmaster = 2 })
    eq(b[1].w, 1920, "full width")
    covers(HD, b, "nmaster 2")
end)

test("threecol centers the master with 25% sides", function()
    local b = geometry.threecol(UW, 3, { mfact = 0.5, nmaster = 1 })
    box_eq(b[1], { x = 860, y = 34, w = 1720, h = 1406 }, "master")
    box_eq(b[2], { x = 2580, y = 34, w = 860, h = 1406 }, "first stack window goes right")
    box_eq(b[3], { x = 0, y = 34, w = 860, h = 1406 }, "second goes left")
end)

test("threecol with two windows is master + one column, 50/50", function()
    local b = geometry.threecol(UW, 2, { mfact = 0.5, nmaster = 1 })
    box_eq(b[1], { x = 0, y = 34, w = 1720, h = 1406 }, "master")
    box_eq(b[2], { x = 1720, y = 34, w = 1720, h = 1406 }, "stack")
end)

test("threecol alternates stack windows right, left, right", function()
    local b = geometry.threecol(UW, 5, { mfact = 0.5, nmaster = 1 })
    eq(b[2].x, 2580, "2 right")
    eq(b[3].x, 0, "3 left")
    eq(b[4].x, 2580, "4 right")
    eq(b[5].x, 0, "5 left")
    eq(b[2].y < b[4].y, true, "right column in order")
    eq(b[3].y < b[5].y, true, "left column in order")
    covers(UW, b, "threecol 5")
end)

test("adding a window to threecol never moves one to the other side", function()
    for n = 3, 7 do
        local a = geometry.threecol(UW, n, { mfact = 0.5, nmaster = 1 })
        local c = geometry.threecol(UW, n + 1, { mfact = 0.5, nmaster = 1 })
        for i = 1, n do
            eq(c[i].x, a[i].x, string.format("window %d of %d keeps its column", i, n))
        end
    end
end)

test("twocol puts two masters side by side and stacks the rest", function()
    local b = geometry.twocol(UW, 5, { mfact = 0.72, nmaster = 2 })
    eq(b[1].h, 1406, "master 1 full height")
    eq(b[2].h, 1406, "master 2 full height")
    eq(b[1].x < b[2].x, true, "masters side by side")
    eq(b[3].x, b[4].x, "stack shares a column")
    eq(b[3].x, b[2].x + b[2].w, "stack right of the masters")
    covers(UW, b, "twocol 5")
end)

test("twocol with no stack shares the width equally", function()
    local b = geometry.twocol(HD, 2, { mfact = 0.72, nmaster = 2 })
    box_eq(b[1], { x = 0, y = 34, w = 960, h = 1046 }, "left")
    box_eq(b[2], { x = 960, y = 34, w = 960, h = 1046 }, "right")
end)

test("monocle gives every window the whole area", function()
    for i, b in ipairs(geometry.monocle(UW, 3)) do
        box_eq(b, UW, "window " .. i)
    end
end)

test("a lone window is 80% on an ultrawide, 60% on 32:9, 100% on 16:9", function()
    box_eq(geometry.single(UW, RULES)[1], { x = 344, y = 34, w = 2752, h = 1406 }, "21:9")
    box_eq(geometry.single(SUW, RULES)[1], { x = 1024, y = 34, w = 3072, h = 1406 }, "32:9")
    box_eq(geometry.single(HD, RULES)[1], HD, "16:9")
end)

test("the single-window rule applies in every mode", function()
    for _, mode in ipairs(geometry.modes) do
        box_eq(geometry.arrange(mode, UW, 1, { mfact = 0.5, nmaster = 1 }, RULES)[1],
            { x = 344, y = 34, w = 2752, h = 1406 }, mode)
    end
end)

test("every mode covers the area for 2 to 9 windows on odd sizes", function()
    local odd = { x = 7, y = 33, w = 2561, h = 1397 }
    local opts = {
        tile = { mfact = 0.55, nmaster = 1 },
        threecol = { mfact = 0.5, nmaster = 1 },
        twocol = { mfact = 0.72, nmaster = 2 },
    }
    for mode, o in pairs(opts) do
        for n = 2, 9 do
            covers(odd, geometry.arrange(mode, odd, n, o, RULES), mode .. " n=" .. n)
        end
    end
end)

test("an unknown mode is an error", function()
    local ok = pcall(geometry.arrange, "spiral", UW, 2, {}, RULES)
    eq(ok, false, "arrange spiral")
end)

-- Whether some box in `boxes` starts at `x`, so an edge sits between tiles.
local function some_box_starts_at(boxes, x)
    for _, b in ipairs(boxes) do
        if b.x == x then
            return true
        end
    end
    return false
end

test("split edges sit exactly where the tiles meet, in every mode", function()
    local odd = { x = 7, y = 33, w = 2561, h = 1397 }
    local opts = {
        tile = { mfact = 0.55, nmaster = 1 },
        threecol = { mfact = 0.5, nmaster = 1 },
        twocol = { mfact = 0.72, nmaster = 2 },
    }
    local want = { tile = 1, twocol = 1 }
    for mode, o in pairs(opts) do
        for n = 2, 9 do
            local boxes = geometry.arrange(mode, odd, n, o, RULES)
            local edges = geometry.split_edges(mode, odd, n, o)
            local count = want[mode] or (n == 2 and 1 or 2)
            if mode == "twocol" and n == 2 then
                count = 0
            end
            eq(#edges, count, mode .. " n=" .. n .. " edge count")
            for i, e in ipairs(edges) do
                eq(some_box_starts_at(boxes, e.x), true, mode .. " n=" .. n .. " edge " .. i .. " at " .. e.x)
            end
        end
    end
end)

test("split edges: tile at 0.55 on 1920, threecol's center pair, none to drag", function()
    local tile = geometry.split_edges("tile", HD, 3, { mfact = 0.55, nmaster = 1 })
    eq(tile[1].x, 1056, "tile edge")
    eq(tile[1].kind, "left", "tile kind")
    local three = geometry.split_edges("threecol", UW, 3, { mfact = 0.5, nmaster = 1 })
    eq(three[1].x, 860, "threecol left side of the master")
    eq(three[2].x, 2580, "threecol right side of the master")
    eq(three[1].kind, "center", "threecol kind")
    eq(three[1].side, "left", "the master's left side")
    eq(three[2].side, "right", "the master's right side")
    eq(#geometry.split_edges("tile", HD, 1, { mfact = 0.55, nmaster = 1 }), 0, "a lone window")
    eq(#geometry.split_edges("tile", HD, 3, { mfact = 0.55, nmaster = 0 }), 0, "tile as rows")
    eq(#geometry.split_edges("tile", HD, 3, { mfact = 0.55, nmaster = 3 }), 0, "all masters")
    eq(#geometry.split_edges("threecol", UW, 2, { mfact = 0.5, nmaster = 2 }), 0, "threecol with no stack")
    eq(#geometry.split_edges("monocle", HD, 3, {}), 0, "monocle")
end)

test("an edge's grab zone straddles it and stays inside the area", function()
    local edges = geometry.split_edges("tile", HD, 2, { mfact = 0.55, nmaster = 1 })
    eq(geometry.edge_at(edges, HD, 1052, 500, 4) ~= nil, true, "4 px left of the edge")
    eq(geometry.edge_at(edges, HD, 1059, 500, 4) ~= nil, true, "3 px right of the edge")
    eq(geometry.edge_at(edges, HD, 1051, 500, 4), nil, "5 px left")
    eq(geometry.edge_at(edges, HD, 1060, 500, 4), nil, "4 px right is the stack's")
    eq(geometry.edge_at(edges, HD, 1056, 20, 4), nil, "on the bar, above the area")
    eq(geometry.edge_at(edges, HD, 1056, 1080, 4), nil, "below the area")
    eq(geometry.edge_at(edges, HD, 1056, 500, 0), nil, "grab 0 grabs nothing")
end)

test("dragging an edge maps the pointer to mfact, clamped", function()
    local left = { x = 1056, kind = "left" }
    eq(geometry.drag_mfact(left, HD, 1152), 0.6, "left edge at 60%")
    eq(geometry.drag_mfact(left, HD, -50), 0.1, "clamped at 0.1")
    eq(geometry.drag_mfact(left, HD, 1915), 0.9, "clamped at 0.9")
    local cleft = { x = 860, kind = "center", side = "left" }
    local cright = { x = 2580, kind = "center", side = "right" }
    eq(geometry.drag_mfact(cleft, UW, 688), 0.6, "left side dragged left grows the master")
    eq(geometry.drag_mfact(cright, UW, 2752), 0.6, "the right side dragged right the same")
    eq(geometry.drag_mfact(cleft, UW, 1720), 0.1, "the left side at the center clamps at 0.1")
    eq(geometry.drag_mfact(cleft, UW, 2752), 0.1, "and past it holds at 0.1, not growing again")
    eq(geometry.drag_mfact(cright, UW, 688), 0.1, "the right side past the center too")
    eq(geometry.drag_mfact(cleft, UW, 0), 0.9, "clamped at 0.9")
    eq(geometry.drag_mfact(cright, UW, 3440), 0.9, "clamped at 0.9 on the right")
end)

test("bounds holds every box, and none have none", function()
    box_eq(geometry.bounds(geometry.arrange("threecol", UW, 5, { mfact = 0.5, nmaster = 1 }, RULES)), UW, "threecol's tiles")
    box_eq(geometry.bounds({ { x = 10, y = 20, w = 5, h = 5 }, { x = 0, y = 30, w = 4, h = 10 } }), { x = 0, y = 20, w = 15, h = 20 }, "two apart")
    eq(geometry.bounds({}), nil, "none")
end)

-- layout.lua against a stub hl ---------------------------------------------

local function stub_hl()
    local h = { registered = {}, dispatched = {}, handlers = {}, notifications = {}, active_ws = 1, active_window = nil }
    h.on = function(ev, fn)
        h.handlers[ev] = fn
    end
    h.notification = {
        create = function(t)
            table.insert(h.notifications, t)
        end,
    }
    h.layout = {
        register = function(name, t)
            h.registered[name] = t
        end,
    }
    h.dsp = {
        event = function(s)
            return { kind = "event", arg = s }
        end,
        layout = function(m)
            return { kind = "layout", arg = m }
        end,
        focus = function(t)
            return { kind = "focus", arg = t.window, monitor = t.monitor }
        end,
        window = {
            swap = function(t)
                return { kind = "swap", arg = t.target }
            end,
            move = function(t)
                return { kind = "move", monitor = t.monitor, follow = t.follow, x = t.x, y = t.y, window = t.window }
            end,
            resize = function(t)
                return { kind = "resize", x = t.x, y = t.y, window = t.window }
            end,
        },
    }
    h.get_active_workspace = function()
        return { id = h.active_ws }
    end
    h.get_active_window = function()
        return h.active_window and { address = h.active_window } or nil
    end
    -- The pointer, its monitor, and what's above the tiles, for drags.
    h.cursor = { x = 0, y = 0 }
    h.monitor = { focused = true, active_workspace_id = 1 }
    h.windows, h.layers = {}, {}
    -- Each workspace's tiled windows, as its last layout had them; the
    -- layout checks them before a drag (tiles_current).
    h.tiled = {}
    h.config = {
        ["general:resize_on_border"] = true,
        ["general:border_size"] = 0,
        ["general:extend_border_grab_area"] = 8,
    }
    h.timers = {}
    h.get_cursor_pos = function()
        return { x = h.cursor.x, y = h.cursor.y }
    end
    h.get_monitor_at_cursor = function()
        local m = h.monitor
        return {
            focused = m.focused,
            active_workspace = { id = m.active_workspace_id, has_fullscreen = m.has_fullscreen or false },
            active_special_workspace = m.special,
        }
    end
    h.get_windows = function()
        local all = {}
        for _, list in pairs(h.tiled) do
            for _, w in ipairs(list) do
                all[#all + 1] = w
            end
        end
        for _, w in ipairs(h.windows) do
            all[#all + 1] = w
        end
        return all
    end
    -- Every monitor, for Super+Left and Right: { name, x, y, width,
    -- height, scale, transform, focused, ws, special, has_fullscreen,
    -- reserved }.
    h.monitors = {}
    h.get_monitors = function()
        local out = {}
        for _, m in ipairs(h.monitors) do
            out[#out + 1] = {
                name = m.name, x = m.x, y = m.y, width = m.width, height = m.height,
                scale = m.scale or 1, transform = m.transform or 0, focused = m.focused or false,
                active_workspace = m.ws and { id = m.ws, has_fullscreen = m.has_fullscreen or false },
                active_special_workspace = m.special and { id = m.special },
                reserved = m.reserved,
            }
        end
        return out
    end
    h.get_layers = function()
        return h.layers
    end
    h.get_config = function(key)
        return h.config[key]
    end
    h.timer = function(fn, opts)
        local t = { fn = fn, opts = opts, enabled = true }
        function t:set_enabled(on)
            self.enabled = on
        end
        table.insert(h.timers, t)
        return t
    end
    -- A layoutmsg dispatch runs the layout's callback, as Hyprland does.
    h.dispatch = function(d)
        table.insert(h.dispatched, d)
        if d.kind == "layout" then
            local r = h.registered.tide.layout_msg({ area = h.area, targets = {} }, d.arg)
            assert(r == true, "layout_msg rejected " .. d.arg .. ": " .. tostring(r))
        end
    end
    return h
end

local function targets(ws, n)
    local list = {}
    for i = 1, n do
        list[i] = {
            window = { address = string.format("0x%x", 0x100 + i), workspace = { id = ws }, mapped = true },
            -- Hyprland puts the window where its target goes.
            place = function(self, box)
                self.placed = box
                self.window.at, self.window.size = { x = box.x, y = box.y }, { x = box.w, y = box.h }
            end,
        }
    end
    return list
end

-- A file that doesn't exist, so a test never reads the real settings.
local NO_SETTINGS = os.tmpname()
os.remove(NO_SETTINGS)

-- layout.lua, fresh, reading its settings from `settings_file` (none by
-- default).
local function load_layout(settings_file)
    local qs = dofile(dir .. "layout.lua")
    qs.settings_file = settings_file or NO_SETTINGS
    return qs
end

local function fresh(opts)
    hl = stub_hl()
    local qs = load_layout()
    qs.setup(opts or {})
    return qs, hl.registered.tide
end

-- A settings file holding `text`, as the shell writes tide-layouts.lua.
local function settings_file(text)
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
    return path
end

-- The windows of targets `t`, as Hyprland lists them, for get_windows.
local function tile(ws, t)
    local list = {}
    for i, target in ipairs(t) do
        list[i] = target.window
    end
    hl.tiled[ws] = list
end

local function relayout(layout, area, ws, n)
    local t = targets(ws, n)
    tile(ws, t)
    layout.recalculate({ area = area, targets = t })
    return t
end

test("setup registers lua:tide", function()
    local _, layout = fresh()
    eq(type(layout.recalculate), "function", "recalculate")
    eq(type(layout.layout_msg), "function", "layout_msg")
end)

test("a workspace starts in threecol on an ultrawide and tile otherwise", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    relayout(layout, HD, 2, 3)
    eq(qs.mode(1), "threecol", "ultrawide")
    eq(qs.mode(2), "tile", "16:9")
end)

test("recalculate places every window and records the order", function()
    local qs, layout = fresh()
    local t = relayout(layout, UW, 1, 3)
    box_eq(t[1].placed, { x = 860, y = 34, w = 1720, h = 1406 }, "master")
    eq(table.concat(qs.order(1), " "), "0x101 0x102 0x103", "order")
end)

test("a window whose address can't be read leaves no hole in the order", function()
    local qs, layout = fresh()
    local t = targets(1, 3)
    t[2].window = setmetatable({}, {
        __index = function(_, k)
            error("window is going away: " .. k)
        end,
    })
    layout.recalculate({ area = UW, targets = t })
    eq(t[2].placed ~= nil, true, "still placed")
    eq(table.concat(qs.order(1), " "), "0x101 0x103", "order")
    hl.active_window = "0x103"
    qs.focus(1)
    eq(hl.dispatched[1].arg, "address:0x101", "focus wraps past the gone window")
end)

test("an empty workspace elsewhere leaves the active workspace's order alone", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    hl.active_ws = 1
    layout.recalculate({ area = HD, targets = {} })
    eq(table.concat(qs.order(1), " "), "0x101 0x102 0x103", "order kept")
    hl.active_window = "0x103"
    qs.focus(1)
    eq(hl.dispatched[1].arg, "address:0x101", "focus still works")
end)

test("windows that can't name their workspace don't touch the active one", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    hl.active_ws = 1
    local ctx = { area = UW, targets = targets(1, 3) }
    layout.layout_msg(ctx, "mode twocol")
    local gone = targets(9, 2)
    for _, t in ipairs(gone) do
        t.window = setmetatable({}, {
            __index = function(_, k)
                error("window is going away: " .. k)
            end,
        })
    end
    layout.recalculate({ area = HD, targets = gone })
    eq(gone[1].placed ~= nil and gone[2].placed ~= nil, true, "still placed")
    eq(table.concat(qs.order(1), " "), "0x101 0x102 0x103", "active order kept")
    eq(qs.mode(1), "twocol", "active mode kept")
end)

test("modes are per workspace", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    relayout(layout, UW, 2, 3)
    layout.layout_msg({ area = UW, targets = targets(1, 3) }, "mode twocol")
    eq(qs.mode(1), "twocol", "workspace 1")
    eq(qs.mode(2), "threecol", "workspace 2")
end)

test("next and prev cycle tile, threecol, twocol", function()
    local qs, layout = fresh()
    relayout(layout, HD, 1, 3)
    local seen = {}
    for _ = 1, 3 do
        layout.layout_msg({ area = HD, targets = targets(1, 3) }, "next")
        seen[#seen + 1] = qs.mode(1)
    end
    eq(table.concat(seen, " "), "threecol twocol tile", "next")
    layout.layout_msg({ area = HD, targets = targets(1, 3) }, "prev")
    eq(qs.mode(1), "twocol", "prev wraps")
end)

test("monocle toggles back to the previous mode, and next leaves it", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    local ctx = { area = UW, targets = targets(1, 3) }
    layout.layout_msg(ctx, "monocle")
    eq(qs.mode(1), "monocle", "on")
    layout.layout_msg(ctx, "monocle")
    eq(qs.mode(1), "threecol", "back")
    layout.layout_msg(ctx, "monocle")
    layout.layout_msg(ctx, "next")
    eq(qs.mode(1), "twocol", "next after the mode before monocle")
end)

test("mfact steps, clamps, and is kept per mode", function()
    local qs, layout = fresh()
    relayout(layout, HD, 1, 2)
    local ctx = { area = HD, targets = targets(1, 2) }
    layout.layout_msg(ctx, "mfact +0.05")
    local t = relayout(layout, HD, 1, 2)
    eq(t[1].placed.w, 1152, "tile master at 0.60")
    layout.layout_msg(ctx, "mfact 5")
    t = relayout(layout, HD, 1, 2)
    eq(t[1].placed.w, 1728, "clamped to 0.9")
    layout.layout_msg(ctx, "mode threecol")
    t = relayout(layout, HD, 1, 2)
    eq(t[1].placed.w, 960, "threecol keeps its own 0.5")
    eq(qs.mode(1), "threecol", "mode")
end)

test("addmaster and removemaster stop at the mode's floor", function()
    local _, layout = fresh()
    relayout(layout, HD, 1, 4)
    local ctx = { area = HD, targets = targets(1, 4) }
    layout.layout_msg(ctx, "removemaster")
    layout.layout_msg(ctx, "removemaster")
    local t = relayout(layout, HD, 1, 4)
    eq(t[1].placed.w, 1920, "tile with no master is full-width rows")
    layout.layout_msg(ctx, "mode twocol")
    for _ = 1, 3 do
        layout.layout_msg(ctx, "removemaster")
    end
    t = relayout(layout, HD, 1, 4)
    eq(t[1].placed.h, 1046, "twocol keeps one master")
end)

test("reset restores the mode's defaults", function()
    local _, layout = fresh()
    relayout(layout, HD, 1, 2)
    local ctx = { area = HD, targets = targets(1, 2) }
    layout.layout_msg(ctx, "mfact 0.3")
    layout.layout_msg(ctx, "reset")
    eq(relayout(layout, HD, 1, 2)[1].placed.w, 1056, "back to 0.55")
end)

test("bad layoutmsgs are refused with a message", function()
    local _, layout = fresh()
    relayout(layout, HD, 1, 2)
    local ctx = { area = HD, targets = targets(1, 2) }
    eq(type(layout.layout_msg(ctx, "spin")), "string", "unknown command")
    eq(type(layout.layout_msg(ctx, "mode spiral")), "string", "unknown mode")
    eq(type(layout.layout_msg(ctx, "mfact lots")), "string", "bad mfact")
end)

test("a layoutmsg on an empty workspace uses the active workspace", function()
    local qs, layout = fresh()
    hl.active_ws = 7
    eq(layout.layout_msg({ area = UW, targets = {} }, "mode twocol"), true, "accepted")
    eq(qs.mode(7), "twocol", "workspace 7")
end)

test("helpers dispatch the layoutmsg, then announce the mode", function()
    local qs, layout = fresh()
    hl.area = UW
    relayout(layout, UW, 1, 3)
    qs.cycle_next()
    eq(hl.dispatched[1].kind, "layout", "first a layoutmsg")
    eq(hl.dispatched[1].arg, "next", "next")
    eq(hl.dispatched[2].kind, "event", "then an event")
    eq(hl.dispatched[2].arg, "tide-layout>>1,twocol", "event text")
    qs.grow()
    eq(hl.dispatched[3].arg, "mfact +0.025", "grow step")
end)

test("a workspace becoming active announces its mode", function()
    local _, layout = fresh()
    relayout(layout, UW, 4, 2)
    hl.handlers["workspace.active"]({ id = 4 })
    eq(#hl.dispatched, 1, "one dispatch")
    eq(hl.dispatched[1].kind, "event", "an event")
    eq(hl.dispatched[1].arg, "tide-layout>>4,threecol", "workspace 4's own mode")
end)

test("a workspace not laid out yet announces nothing", function()
    fresh()
    hl.handlers["workspace.active"]({ id = 5 })
    eq(#hl.dispatched, 0, "no mode to announce")
end)

test("swap_with_master swaps with the master, or zooms the master", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    hl.active_window = "0x103"
    qs.swap_with_master()
    eq(hl.dispatched[1].arg, "address:0x101", "stack window swaps with the master")
    hl.active_window = "0x101"
    qs.swap_with_master()
    eq(hl.dispatched[2].arg, "address:0x102", "master swaps with the first stack window")
end)

test("focus wraps around the layout order", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    hl.active_window = "0x103"
    qs.focus(1)
    eq(hl.dispatched[1].arg, "address:0x101", "next wraps to the master")
    qs.focus(-1)
    eq(hl.dispatched[2].arg, "address:0x102", "previous")
end)

test("move stops at the ends of the order", function()
    local qs, layout = fresh()
    relayout(layout, UW, 1, 3)
    hl.active_window = "0x101"
    qs.move(-1)
    eq(#hl.dispatched, 0, "nothing above the master")
    qs.move(1)
    eq(hl.dispatched[1].arg, "address:0x102", "down one")
end)

test("setup options merge objects and replace lists", function()
    hl = stub_hl()
    local qs = load_layout()
    qs.setup({ modes = { tile = { mfact = 0.6 } }, single = { { min_aspect = 2.0, width = 0.5 } } })
    local layout = hl.registered.tide
    local t = relayout(layout, HD, 1, 2)
    eq(t[1].placed.w, 1152, "tile mfact overridden")
    t = relayout(layout, UW, 2, 1)
    eq(t[1].placed.w, 1720, "single rules replaced")
    layout.layout_msg({ area = HD, targets = targets(1, 2) }, "removemaster")
    eq(relayout(layout, HD, 1, 2)[1].placed.w, 1920, "tile nmaster still defaulted to 1")
end)

test("an empty list override replaces the default list", function()
    hl = stub_hl()
    local qs = load_layout()
    qs.setup({ single = {} })
    local t = relayout(hl.registered.tide, UW, 1, 1)
    box_eq(t[1].placed, UW, "no single-window rule means full width")
end)

test("setup rejects bad options with a message instead of failing later", function()
    local bad = {
        { cycle = {} },
        { cycle = { "tile", "spiral" } },
        { single = { { min_aspect = 2.1, width = 0 } } },
        { single = { "wide" } },
        { modes = { tile = { mfact = 1.5 } } },
        { modes = { twocol = { nmaster = 1.5 } } },
        { mfact_step = 0 },
        { ultrawide_aspect = "wide" },
        { new_window = "left" },
    }
    for i, opts in ipairs(bad) do
        hl = stub_hl()
        local qs = load_layout()
        local ok, err = pcall(qs.setup, opts)
        eq(ok, false, "bad option set " .. i .. " accepted")
        eq(tostring(err):find("tide.setup: ", 1, true) ~= nil, true, "message for set " .. i .. ": " .. tostring(err))
        eq(hl.registered.tide, nil, "nothing registered for set " .. i)
    end
end)

test("setup names the path of a typo or a hole", function()
    local cases = {
        { { modes = { tile = { mfat = 0.6 } } }, "modes.tile.mfat is not an option" },
        { { cylce = { "tile" } }, "cylce is not an option" },
        { { modes = { tiles = {} } }, "modes.tiles is not an option" },
        { { single = { { min_aspect = 2.1, width = 0.8, widht = 0.7 } } }, "single[1].widht is not an option" },
        { { cycle = { "tile", nil, "twocol" } }, "cycle has a hole at [2]" },
        { { single = { { min_aspect = 2.1, width = 0.8 }, nil, { min_aspect = 3, width = 0.6 } } }, "single has a hole at [2]" },
        { { cycle = { first = "tile" } }, "cycle must be a list, not a table" },
        { { modes = { monocle = { mfact = 0.5 } } }, "modes.monocle.mfact is not an option" },
        { { cycle = { "tile", "monocle", "threecol" } }, "cycle[2] must be tile, threecol or twocol, not monocle" },
        { { single = { { min_aspect = 2.1 } } }, "single[1].width is required" },
        { { single = { { width = 0.8 } } }, "single[1].min_aspect is required" },
        { { cycle = { "tile", "threecol", "tile", "twocol" } }, "cycle[3] repeats tile from [1]" },
    }
    for _, case in ipairs(cases) do
        hl = stub_hl()
        local qs = load_layout()
        local ok, err = pcall(qs.setup, case[1])
        eq(ok, false, case[2] .. " accepted")
        eq(tostring(err):find(case[2], 1, true) ~= nil, true, "message: " .. tostring(err))
    end
end)

test("next and prev enter a cycle that omits the current mode at its ends", function()
    hl = stub_hl()
    local qs = load_layout()
    qs.setup({ cycle = { "tile", "twocol" } })
    local layout = hl.registered.tide
    relayout(layout, UW, 1, 3)
    relayout(layout, UW, 2, 3)
    eq(qs.mode(1), "threecol", "an ultrawide still starts in threecol")
    layout.layout_msg({ area = UW, targets = targets(1, 3) }, "next")
    eq(qs.mode(1), "tile", "next enters at the first entry")
    layout.layout_msg({ area = UW, targets = targets(2, 3) }, "prev")
    eq(qs.mode(2), "twocol", "prev enters at the last entry")
    local ctx = { area = UW, targets = targets(2, 3) }
    layout.layout_msg(ctx, "mode threecol")
    layout.layout_msg(ctx, "monocle")
    layout.layout_msg(ctx, "next")
    eq(qs.mode(2), "tile", "from monocle over an omitted mode too")
end)

test("setup rejects NaN and a zero master count where a mode needs one", function()
    local cases = {
        { { modes = { tile = { mfact = 0 / 0 } } }, "modes.tile.mfact must be a number" },
        { { single = { { min_aspect = 0 / 0, width = 0.8 } } }, "single[1].min_aspect must be a number" },
        { { modes = { threecol = { nmaster = 0 } } }, "modes.threecol.nmaster must be a whole number from 1" },
        { { modes = { twocol = { nmaster = 0 } } }, "modes.twocol.nmaster must be a whole number from 1" },
    }
    for _, case in ipairs(cases) do
        hl = stub_hl()
        local qs = load_layout()
        local ok, err = pcall(qs.setup, case[1])
        eq(ok, false, case[2] .. " accepted")
        eq(tostring(err):find(case[2], 1, true) ~= nil, true, "message: " .. tostring(err))
    end
    hl = stub_hl()
    local qs = load_layout()
    qs.setup({ modes = { tile = { nmaster = 0 } } })
    eq(hl.registered.tide ~= nil, true, "tile still accepts no master")
end)

test("setup accepts a one-mode cycle and an empty single list", function()
    hl = stub_hl()
    local qs = load_layout()
    qs.setup({ cycle = { "tile" }, single = {} })
    local layout = hl.registered.tide
    relayout(layout, HD, 1, 2)
    layout.layout_msg({ area = HD, targets = targets(1, 2) }, "next")
    eq(qs.mode(1), "tile", "a one-mode cycle stays put")
end)

test("a new workspace starts in the mode set for its aspect", function()
    hl = stub_hl()
    local qs = load_layout()
    qs.setup({ default_mode = { normal = "monocle", ultrawide = "twocol" } })
    local layout = hl.registered.tide
    relayout(layout, HD, 1, 2)
    relayout(layout, UW, 2, 2)
    eq(qs.mode(1), "monocle", "16:9")
    eq(qs.mode(2), "twocol", "ultrawide")
    -- Started in monocle, there's no mode before it to go on from.
    layout.layout_msg({ area = HD, targets = targets(1, 2) }, "next")
    eq(qs.mode(1), "tile", "next from a starting monocle enters at the first entry")
    relayout(layout, HD, 3, 2)
    layout.layout_msg({ area = HD, targets = targets(3, 2) }, "prev")
    eq(qs.mode(3), "twocol", "prev from a starting monocle enters at the last entry")
    hl = stub_hl()
    local ok, err = pcall(load_layout().setup, { default_mode = { normal = "spiral" } })
    eq(ok, false, "an unknown mode accepted")
    eq(tostring(err):find("default_mode.normal must be tile, threecol, twocol or monocle, not spiral", 1, true) ~= nil, true, "message: " .. tostring(err))
end)

test("the settings file goes over setup's options", function()
    hl = stub_hl()
    local path = settings_file('return { modes = { tile = { mfact = 0.6 } }, default_mode = { ultrawide = "tile" } }\n')
    local qs = load_layout(path)
    qs.setup({ modes = { tile = { mfact = 0.5 } } })
    local layout = hl.registered.tide
    local t = relayout(layout, HD, 1, 2)
    eq(t[1].placed.w, 1152, "the file's tile mfact")
    relayout(layout, UW, 2, 2)
    eq(qs.mode(2), "tile", "the file's ultrawide mode")
    eq(#hl.notifications, 0, "nothing to report")
    os.remove(path)
end)

test("a settings file that can't be used is reported, and setup goes on without it", function()
    for _, case in ipairs({
        { "return { modes = { tile = { mfat = 0.6 } } }\n", "modes.tile.mfat is not an option" },
        { "return {\n", "expected" },
        { "return 5\n", "expected a table, not number" },
        -- It runs with no globals, so it can do nothing but return data.
        { "return os.exit(1)\n", "os" },
    }) do
        hl = stub_hl()
        local path = settings_file(case[1])
        local qs = load_layout(path)
        qs.setup({})
        eq(hl.registered.tide ~= nil, true, "registered anyway for " .. case[2])
        eq(#hl.notifications, 1, "one notification for " .. case[2])
        local text = hl.notifications[1].text
        eq(text:find(case[2], 1, true) ~= nil, true, "names the problem: " .. text)
        relayout(hl.registered.tide, UW, 1, 2)
        eq(qs.mode(1), "threecol", "the defaults hold for " .. case[2])
        os.remove(path)
    end
end)

test("reload takes the settings file again, keeping each workspace's mode", function()
    hl = stub_hl()
    local path = os.tmpname()
    os.remove(path)
    local qs = load_layout(path)
    qs.setup({})
    local layout = hl.registered.tide
    relayout(layout, UW, 1, 3)
    layout.layout_msg({ area = UW, targets = targets(1, 3) }, "mode tile")
    local f = assert(io.open(path, "w"))
    f:write('return { modes = { tile = { mfact = 0.6 } }, default_mode = { ultrawide = "twocol" } }\n')
    f:close()
    tide_layout.reload()
    eq(qs.mode(1), "tile", "the mode stays")
    local t = relayout(layout, UW, 1, 3)
    eq(t[1].placed.w, 2064, "the new tile mfact")
    relayout(layout, UW, 2, 3)
    eq(qs.mode(2), "twocol", "a new workspace takes the new default")
    local last = hl.dispatched[#hl.dispatched]
    eq(last.kind .. " " .. last.arg, "layout refresh", "the active workspace is laid out again")
    os.remove(path)
end)

test("reload refuses a settings file that can't be used, and changes nothing", function()
    hl = stub_hl()
    local path = settings_file("return { modes = { tile = { mfact = 0.6 } } }\n")
    local qs = load_layout(path)
    qs.setup({})
    local f = assert(io.open(path, "w"))
    f:write("return { cycle = {} }\n")
    f:close()
    local before = #hl.dispatched
    local ok, err = pcall(tide_layout.reload)
    eq(ok, false, "a bad file accepted")
    eq(tostring(err):find(path .. ": cycle must have at least 1 entry", 1, true) ~= nil, true, "message: " .. tostring(err))
    eq(#hl.dispatched, before, "nothing laid out again")
    local t = relayout(hl.registered.tide, HD, 1, 2)
    eq(t[1].placed.w, 1152, "the last good settings hold")
    os.remove(path)
end)

-- new windows -----------------------------------------------------------------

-- Targets on workspace `ws` for the windows `ids` (0x101 is 1), in
-- Hyprland's order.
local function windows(ws, ids)
    local list = {}
    for i, id in ipairs(ids) do
        list[i] = {
            window = { address = string.format("0x%x", 0x100 + id), workspace = { id = ws }, mapped = true },
            -- Hyprland puts the window where its target goes.
            place = function(self, box)
                self.placed = box
                self.window.at, self.window.size = { x = box.x, y = box.y }, { x = box.w, y = box.h }
            end,
        }
    end
    return list
end

local function lay(layout, area, ws, ids)
    local t = windows(ws, ids)
    tile(ws, t)
    layout.recalculate({ area = area, targets = t })
    return t
end

local function order_of(qs, ws)
    return table.concat(qs.order(ws), " ")
end

-- Tile's boxes for `n` windows on HD, by place in the order.
local function tile_boxes(n)
    return geometry.arrange("tile", HD, n, { mfact = 0.55, nmaster = 1 }, RULES)
end

test("a new window joins the end of the stack by default", function()
    local qs, layout = fresh()
    lay(layout, HD, 1, { 1, 2 })
    local t = lay(layout, HD, 1, { 1, 2, 3 })
    eq(order_of(qs, 1), "0x101 0x102 0x103", "order")
    box_eq(t[3].placed, tile_boxes(3)[3], "last in the stack")
end)

test("new_window = master makes a new window the master, keeping the rest's order", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1, 2 })
    local t = lay(layout, HD, 1, { 1, 2, 3 })
    eq(order_of(qs, 1), "0x103 0x101 0x102", "order")
    local boxes = tile_boxes(3)
    box_eq(t[3].placed, boxes[1], "the new window is the master")
    box_eq(t[1].placed, boxes[2], "the old master tops the stack")
    box_eq(t[2].placed, boxes[3], "and the stack follows")
end)

test("new_window = top puts a new window just after the masters", function()
    local qs, layout = fresh({ new_window = "top" })
    lay(layout, HD, 1, { 1, 2, 3 })
    lay(layout, HD, 1, { 1, 2, 3, 4 })
    eq(order_of(qs, 1), "0x101 0x104 0x102 0x103", "after tile's one master")
    lay(layout, UW, 2, { 1, 2, 3 })
    layout.layout_msg({ area = UW, targets = windows(2, { 1, 2, 3 }) }, "mode twocol")
    lay(layout, UW, 2, { 1, 2, 3, 4 })
    eq(order_of(qs, 2), "0x101 0x102 0x104 0x103", "after twocol's two")
    lay(layout, HD, 3, { 1, 2 })
    layout.layout_msg({ area = HD, targets = windows(3, { 1, 2 }) }, "mode monocle")
    lay(layout, HD, 3, { 1, 2, 3 })
    eq(order_of(qs, 3), "0x101 0x103 0x102", "monocle's first window counts as the master")
    lay(layout, HD, 4, { 1 })
    layout.layout_msg({ area = HD, targets = windows(4, { 1 }) }, "removemaster")
    lay(layout, HD, 4, { 1, 2 })
    eq(order_of(qs, 4), "0x102 0x101", "first, with no masters")
end)

test("new_window = next puts a new window after the focused one", function()
    local qs, layout = fresh({ new_window = "next" })
    lay(layout, HD, 1, { 1, 2, 3 })
    hl.active_window = "0x101"
    lay(layout, HD, 1, { 1, 2, 3, 4 })
    eq(order_of(qs, 1), "0x101 0x104 0x102 0x103", "after the focused window")
    hl.active_window = "0x199"
    lay(layout, HD, 1, { 1, 2, 3, 4, 5 })
    eq(order_of(qs, 1), "0x101 0x104 0x102 0x103 0x105", "at the end when the focused window is elsewhere")
    hl.active_window = nil
    lay(layout, HD, 1, { 1, 2, 3, 4, 5, 6 })
    eq(order_of(qs, 1), "0x101 0x104 0x102 0x103 0x105 0x106", "at the end with none focused")
end)

test("two new windows at once keep their own order", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1 })
    lay(layout, HD, 1, { 1, 2, 3 })
    eq(order_of(qs, 1), "0x102 0x103 0x101", "order")
end)

test("the layout makes Hyprland's swaps in its own order", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1 })
    lay(layout, HD, 1, { 1, 2 })
    lay(layout, HD, 1, { 1, 2, 3 })
    eq(order_of(qs, 1), "0x103 0x102 0x101", "each new window the master")
    -- Super+Shift+J on the master swaps it with the next in the layout's
    -- order, which is last in Hyprland's.
    hl.active_window = "0x103"
    qs.move(1)
    eq(hl.dispatched[1].arg, "address:0x102", "swaps with the next")
    local t = lay(layout, HD, 1, { 1, 3, 2 })
    eq(order_of(qs, 1), "0x102 0x103 0x101", "the master moved down one")
    box_eq(t[3].placed, tile_boxes(3)[1], "and its neighbor is the master")
    -- Alt+Tab on the last window swaps it with the master.
    hl.active_window = "0x101"
    qs.swap_with_master()
    eq(hl.dispatched[2].arg, "address:0x102", "swaps with the master")
    lay(layout, HD, 1, { 2, 3, 1 })
    eq(order_of(qs, 1), "0x101 0x103 0x102", "the last window is the master")
end)

test("swap_with_master on the master goes back to the master before it", function()
    local qs, layout = fresh()
    lay(layout, HD, 1, { 1, 2, 3 })
    hl.active_window = "0x103"
    qs.swap_with_master()
    eq(hl.dispatched[1].arg, "address:0x101", "the stack's last window swaps with the master")
    -- Hyprland swaps them, and lays the workspace out again.
    lay(layout, HD, 1, { 3, 2, 1 })
    eq(order_of(qs, 1), "0x103 0x102 0x101", "it's the master")
    qs.swap_with_master()
    eq(hl.dispatched[#hl.dispatched].arg, "address:0x101", "back with the master before it, not the top of the stack")
    lay(layout, HD, 1, { 1, 2, 3 })
    hl.active_window = "0x101"
    qs.swap_with_master()
    eq(hl.dispatched[#hl.dispatched].arg, "address:0x103", "and again: presses go back and forth")
end)

test("a master that changed another way is the one Alt+Tab goes back to", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1 })
    lay(layout, HD, 1, { 1, 2 })
    lay(layout, HD, 1, { 1, 2, 3 })
    eq(order_of(qs, 1), "0x103 0x102 0x101", "each new window came in as the master")
    hl.active_window = "0x101"
    qs.swap_with_master()
    eq(hl.dispatched[#hl.dispatched].arg, "address:0x103", "the stack's last window takes the master")
    -- Hyprland swaps the two in its own list.
    lay(layout, HD, 1, { 3, 2, 1 })
    eq(order_of(qs, 1), "0x101 0x102 0x103")
    -- A new window comes in as the master: the one it displaced is the
    -- master before it, not the one Alt+Tab last swapped.
    lay(layout, HD, 1, { 3, 2, 1, 4 })
    eq(order_of(qs, 1), "0x104 0x101 0x102 0x103")
    hl.active_window = "0x104"
    qs.swap_with_master()
    eq(hl.dispatched[#hl.dispatched].arg, "address:0x101", "back with the master it displaced")
end)

test("a master moved up by Super+Shift+K is the new one to come back from", function()
    local qs, layout = fresh()
    lay(layout, HD, 1, { 1, 2, 3 })
    -- Super+Shift+K on the second window: Hyprland swaps it with the master.
    lay(layout, HD, 1, { 2, 1, 3 })
    eq(order_of(qs, 1), "0x102 0x101 0x103")
    hl.active_window = "0x102"
    qs.swap_with_master()
    eq(hl.dispatched[#hl.dispatched].arg, "address:0x101", "back with the master before it")
end)

test("swap_with_master takes the top of the stack once the master before is gone", function()
    local qs, layout = fresh()
    lay(layout, HD, 1, { 1, 2, 3 })
    hl.active_window = "0x103"
    qs.swap_with_master()
    lay(layout, HD, 1, { 3, 2, 1 })
    lay(layout, HD, 1, { 3, 2 })
    qs.swap_with_master()
    eq(hl.dispatched[#hl.dispatched].arg, "address:0x102", "the top of the stack")
end)

test("a window that leaves takes nothing else with it", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1 })
    lay(layout, HD, 1, { 1, 2 })
    lay(layout, HD, 1, { 1, 2, 3 })
    local t = lay(layout, HD, 1, { 1, 3 })
    eq(order_of(qs, 1), "0x103 0x101", "order")
    box_eq(t[2].placed, tile_boxes(2)[1], "the master stays the master")
end)

test("a change that isn't one swap takes Hyprland's order", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1 })
    lay(layout, HD, 1, { 1, 2 })
    lay(layout, HD, 1, { 1, 2, 3 })
    lay(layout, HD, 1, { 2, 3, 1 })
    eq(order_of(qs, 1), "0x102 0x103 0x101", "order")
end)

test("a config load takes the windows in Hyprland's order", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1 })
    lay(layout, HD, 1, { 1, 2 })
    qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1, 2 })
    eq(order_of(qs, 1), "0x101 0x102", "order")
end)

test("a window that can't be read takes a place after the rest", function()
    local qs, layout = fresh({ new_window = "master" })
    lay(layout, HD, 1, { 1 })
    local t = windows(1, { 1, 2, 3 })
    t[2].window = setmetatable({}, {
        __index = function(_, k)
            error("window is going away: " .. k)
        end,
    })
    layout.recalculate({ area = HD, targets = t })
    eq(order_of(qs, 1), "0x103 0x101", "order")
    local boxes = tile_boxes(3)
    box_eq(t[3].placed, boxes[1], "the new window is the master")
    box_eq(t[1].placed, boxes[2], "then the old one")
    box_eq(t[2].placed, boxes[3], "then the one going away")
end)

test("reload takes a new new_window for the next new window", function()
    local path = settings_file("return { new_window = \"master\" }\n")
    hl = stub_hl()
    local qs = load_layout(path)
    qs.setup({})
    local layout = hl.registered.tide
    lay(layout, HD, 1, { 1 })
    lay(layout, HD, 1, { 1, 2 })
    eq(order_of(qs, 1), "0x102 0x101", "master from the settings file")
    local f = assert(io.open(path, "w"))
    f:write("return { new_window = \"end\" }\n")
    f:close()
    tide_layout.reload()
    lay(layout, HD, 1, { 1, 2, 3 })
    eq(order_of(qs, 1), "0x102 0x101 0x103", "the end after a reload, the rest kept")
    os.remove(path)
end)

-- drags on a split edge ------------------------------------------------------

-- The layoutmsgs dispatched since `from`, as text.
local function layout_msgs(from)
    local out = {}
    for i = from + 1, #hl.dispatched do
        if hl.dispatched[i].kind == "layout" then
            out[#out + 1] = hl.dispatched[i].arg
        end
    end
    return table.concat(out, " | ")
end

-- Each enabled timer fires once, as Hyprland's event loop would.
local function tick()
    for _, t in ipairs(hl.timers) do
        if t.enabled then
            t.fn()
        end
    end
end

local function drag_setup(opts)
    local qs, layout = fresh(opts)
    hl.area = HD
    relayout(layout, HD, 1, 3)
    return qs, layout
end

test("a press on the master/stack edge starts a drag that follows the pointer", function()
    local qs, layout = drag_setup()
    hl.cursor = { x = 1058, y = 500 }
    eq(qs.drag_press(), nil, "the press is taken")
    eq(#hl.timers, 1, "a timer follows the pointer")
    eq(hl.timers[1].opts.type, "repeat", "repeating")
    local from = #hl.dispatched
    tick()
    eq(layout_msgs(from), "", "no move, no layoutmsg")
    hl.cursor.x = 1154
    tick()
    eq(layout_msgs(from), "mfact 0.6000", "the edge, not the pointer, lands at 60%")
    tick()
    eq(layout_msgs(from), "mfact 0.6000", "nothing again while the pointer stays")
    hl.cursor.x = 1250
    qs.drag_release()
    eq(layout_msgs(from), "mfact 0.6000 | mfact 0.6500", "release takes the last step")
    eq(hl.timers[1].enabled, false, "and stops the timer")
    local t = relayout(layout, HD, 1, 3)
    eq(t[1].placed.w, 1248, "master at 0.65")
    from = #hl.dispatched
    hl.cursor.x = 400
    tick()
    qs.drag_release()
    eq(layout_msgs(from), "", "after release nothing follows the pointer")
end)

test("a drag reuses its timer and clamps at mfact's ends", function()
    local qs = drag_setup()
    hl.cursor = { x = 1056, y = 500 }
    qs.drag_press()
    local from = #hl.dispatched
    hl.cursor.x = -300
    tick()
    hl.cursor.x = 5000
    qs.drag_release()
    eq(layout_msgs(from), "mfact 0.1000 | mfact 0.9000", "clamped both ways")
    hl.cursor = { x = 1728, y = 500 }
    eq(qs.drag_press(), nil, "the edge is at 0.9 now")
    eq(#hl.timers, 1, "the same timer")
    eq(hl.timers[1].enabled, true, "enabled again")
    qs.drag_release()
end)

test("an emptied workspace keeps no edge to drag", function()
    -- Its last tiled windows leave together, and Hyprland calls no
    -- recalculate for none, so what it last placed is still there to find.
    local qs, layout = drag_setup()
    hl.tiled[1] = {}
    layout.recalculate({ area = HD, targets = {} })
    hl.cursor = { x = 1056, y = 500 }
    local from = #hl.dispatched
    local r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "the press on the old edge passes on")
    eq(#hl.timers, 0, "no drag")
    qs.drag_release()
    eq(layout_msgs(from), "", "and the saved mfact is untouched")
end)

test("a workspace whose tiles moved elsewhere keeps no edge to drag", function()
    local qs = drag_setup()
    -- All three moved to workspace 2, which isn't shown.
    for _, w in ipairs(hl.tiled[1]) do
        w.workspace = { id = 2 }
    end
    hl.cursor = { x = 1056, y = 500 }
    local r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "passes on")
    eq(#hl.timers, 0, "no drag")
end)

-- Moves workspace `ws`'s windows, as Hyprland has them, to where tile
-- puts `n` of them on `area`, with no recalculate to tell the layout.
local function move_tiles(ws, area, n)
    local boxes = geometry.arrange("tile", area, n, { mfact = 0.55, nmaster = 1 }, RULES)
    for i, w in ipairs(hl.tiled[ws]) do
        local b = boxes[i]
        w.at, w.size = { x = b.x, y = b.y }, { x = b.w, y = b.h }
    end
end

test("a press finds the edge where the windows are now, not where they were laid out", function()
    local qs = drag_setup()
    -- The monitor moved 1920 px right, and the windows with it.
    local moved = { x = 1920, y = 34, w = 1920, h = 1046 }
    move_tiles(1, moved, 3)
    hl.cursor = { x = 1056, y = 500 }
    local r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "the old edge passes on")
    eq(#hl.timers, 0, "no drag")
    hl.cursor = { x = 1920 + 1056, y = 500 }
    eq(qs.drag_press(), nil, "the edge where the windows are now is taken")
    local from = #hl.dispatched
    hl.cursor.x = 1920 + 1152
    qs.drag_release()
    eq(layout_msgs(from), "mfact 0.6000", "the pointer maps to mfact across where the windows are")
end)

test("a press finds the edge of windows resized since they were laid out", function()
    local qs = drag_setup()
    -- Half the width, under a taller bar.
    local half = { x = 0, y = 100, w = 960, h = 980 }
    move_tiles(1, half, 3)
    hl.cursor = { x = 1056, y = 500 }
    local r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "the old edge, now inside a stack window, passes on")
    hl.cursor = { x = 528, y = 60 }
    r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "above the windows now passes on")
    hl.cursor = { x = 528, y = 500 }
    eq(qs.drag_press(), nil, "the edge at 55% of the narrower windows is taken")
    local from = #hl.dispatched
    hl.cursor.x = 576
    qs.drag_release()
    eq(layout_msgs(from), "mfact 0.6000", "and maps to mfact across their width")
end)

test("a press counts only the windows tiled there now", function()
    -- threecol with two windows has one edge, at the middle; with three it
    -- has two, either side of the master.
    local qs, layout = fresh()
    hl.area = UW
    relayout(layout, UW, 1, 2)
    local function gone(w)
        table.insert(hl.tiled[1], w)
    end
    local whole = { x = 1720, y = 34 }
    gone({ address = "0x201", workspace = { id = 1 }, mapped = false, at = whole, size = { x = 860, y = 1406 } })
    gone({ address = "0x202", workspace = { id = 1 }, mapped = true, hidden = true, at = whole, size = { x = 860, y = 1406 } })
    gone({ address = "0x203", workspace = { id = 1 }, mapped = true, floating = true, visible = false, at = whole, size = { x = 860, y = 1406 } })
    gone({ address = "0x204", workspace = { id = 2 }, mapped = true, at = whole, size = { x = 860, y = 1406 } })
    hl.cursor = { x = 860, y = 700 }
    local r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "no three-window edge from an unmapped, hidden, floating or elsewhere window")
    hl.cursor = { x = 1720, y = 700 }
    eq(qs.drag_press(), nil, "the two windows' edge is taken")
    qs.drag_release()
    -- One of the two left without a recalculate: a lone window has no edge.
    table.remove(hl.tiled[1], 2)
    r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "a lone window's old edge passes on")
end)

test("a press passes when the layers can't be read", function()
    local qs = drag_setup()
    hl.cursor = { x = 1056, y = 500 }
    hl.get_layers = function()
        error("no layers")
    end
    local r = qs.drag_press()
    eq(r and r.pass_event, true, "passes")
    eq(#hl.timers, 0, "no drag")
end)

test("a press passes on when the windows can't be read", function()
    local qs = drag_setup()
    hl.get_windows = function()
        error("gone")
    end
    hl.cursor = { x = 1056, y = 500 }
    local r = qs.drag_press()
    eq(type(r) == "table" and r.pass_event, true, "passes on")
end)

test("presses that aren't on an edge pass through to the window", function()
    local qs = drag_setup()
    local function passes(what)
        local r = qs.drag_press()
        eq(type(r) == "table" and r.pass_event, true, what)
        eq(#hl.timers, 0, what .. ": no drag")
    end
    hl.cursor = { x = 1000, y = 500 }
    passes("inside the master")
    hl.cursor = { x = 1056, y = 20 }
    passes("on the bar above the edge")
    hl.cursor = { x = 1056, y = 500 }
    hl.windows = { { floating = true, visible = true, at = { x = 900, y = 400 }, size = { x = 300, y = 200 } } }
    passes("on a floating window over the edge")
    hl.windows = { { floating = true, visible = true, at = { x = 1062, y = 400 }, size = { x = 300, y = 200 } } }
    passes("in a floating window's own border-resize ring")
    hl.windows = { { floating = true, visible = false, at = { x = 900, y = 400 }, size = { x = 300, y = 200 } } }
    hl.layers = { { mapped = true, layer = 3, x = 1000, y = 450, w = 200, h = 100 } }
    passes("on a notification, an overlay layer")
    hl.layers = {}
    hl.monitor.focused = false
    passes("on a monitor that isn't focused, where a layoutmsg wouldn't go")
    hl.monitor.focused = true
    hl.monitor.has_fullscreen = true
    passes("under a fullscreen or maximized window")
    hl.monitor.has_fullscreen = false
    hl.monitor.special = { id = -99 }
    passes("with a special workspace shown")
    hl.monitor.special = nil
    hl.monitor.active_workspace_id = 2
    passes("on a workspace the layout hasn't laid out")
    hl.monitor.active_workspace_id = 1
    hl.windows = { { floating = true, visible = false, at = { x = 900, y = 400 }, size = { x = 300, y = 200 } } }
    hl.layers = { { mapped = true, layer = 0, x = 0, y = 0, w = 1920, h = 1080 } }
    eq(qs.drag_press(), nil, "a hidden float and the wallpaper don't cover it")
    qs.drag_release()
end)

test("while the shell has a popover open, every press passes", function()
    local qs = drag_setup()
    hl.cursor = { x = 1056, y = 500 }
    tide_layout.set_popups_open(true)
    local r = qs.drag_press()
    eq(r and r.pass_event, true, "a popover over the edge keeps its click")
    eq(#hl.timers, 0, "no drag")
    tide_layout.set_popups_open(false)
    eq(qs.drag_press(), nil, "closed again, the edge drags")
    qs.drag_release()
    for _, bad in ipairs({ "true", 1 }) do
        local ok, err = pcall(tide_layout.set_popups_open, bad)
        eq(ok, false, "set_popups_open(" .. tostring(bad) .. ") accepted")
        eq(tostring(err):find("expects true or false", 1, true) ~= nil, true, tostring(err))
    end
end)

test("a config load forgets an open popover until the shell says again", function()
    local qs = drag_setup()
    tide_layout.set_popups_open(true)
    qs.setup({})
    relayout(hl.registered.tide, HD, 1, 3)
    hl.cursor = { x = 1056, y = 500 }
    eq(qs.drag_press(), nil, "the shell resends after a config load")
    qs.drag_release()
end)

test("a press passes when what's above the tiles can't be read", function()
    local qs = drag_setup()
    hl.cursor = { x = 1056, y = 500 }
    hl.get_windows = function()
        error("no windows")
    end
    local r = qs.drag_press()
    eq(r and r.pass_event, true, "passes")
end)

test("resize_grab sets the zone, and 0 turns edge drags off", function()
    local qs = drag_setup({ resize_grab = 10 })
    hl.cursor = { x = 1047, y = 500 }
    eq(qs.drag_press(), nil, "9 px left with a 10 px grab")
    qs.drag_release()
    qs = drag_setup({ resize_grab = 0 })
    hl.cursor = { x = 1056, y = 500 }
    local r = qs.drag_press()
    eq(r and r.pass_event, true, "off")
    for _, bad in ipairs({ -1, 2.5, 100 }) do
        hl = stub_hl()
        local ok = pcall(load_layout().setup, { resize_grab = bad })
        eq(ok, false, "resize_grab " .. bad .. " accepted")
    end
end)

test("a drag pauses while another workspace is focused and ends on a mode change", function()
    local qs, layout = drag_setup()
    relayout(layout, HD, 2, 2)
    hl.cursor = { x = 1056, y = 500 }
    qs.drag_press()
    local from = #hl.dispatched
    hl.active_ws = 2
    hl.cursor.x = 1152
    tick()
    eq(layout_msgs(from), "", "workspace 2's layout is left alone")
    hl.active_ws = 1
    tick()
    eq(layout_msgs(from), "mfact 0.6000", "back on workspace 1")
    layout.layout_msg({ area = HD, targets = {} }, "mode twocol")
    from = #hl.dispatched
    hl.cursor.x = 1300
    tick()
    eq(layout_msgs(from), "", "no mfact for a mode the drag didn't start in")
    eq(hl.timers[1].enabled, false, "the drag is over")
end)

test("dragging either side of threecol's centered master grows it both ways", function()
    local qs, layout = fresh()
    hl.area = UW
    relayout(layout, UW, 1, 3)
    eq(qs.mode(1), "threecol", "ultrawide starts in threecol")
    hl.cursor = { x = 860, y = 700 }
    eq(qs.drag_press(), nil, "the master's left side")
    local from = #hl.dispatched
    hl.cursor.x = 688
    qs.drag_release()
    eq(layout_msgs(from), "mfact 0.6000", "dragged left, the master grows")
    local t = relayout(layout, UW, 1, 3)
    eq(t[1].placed.w, 2064, "60% of 3440, centered")
    eq(t[1].placed.x, 688, "both sides moved")
end)

-- Super+Left and Right ------------------------------------------------------

-- Two 1920x1080 monitors side by side, A showing workspace 1 and B
-- workspace 2, each below a 34 px bar.
local HD_B = { x = 1920, y = 34, w = 1920, h = 1046 }
local function two_monitors()
    local qs, layout = fresh()
    hl.monitors = {
        { name = "A", x = 0, y = 0, width = 1920, height = 1080, ws = 1, focused = true },
        { name = "B", x = 1920, y = 0, width = 1920, height = 1080, ws = 2 },
    }
    return qs, layout
end

local function last()
    return hl.dispatched[#hl.dispatched]
end

test("Super+Left and Right focus the window that way, then the next monitor's", function()
    local qs, layout = two_monitors()
    lay(layout, HD, 1, { 1, 2, 3 })
    lay(layout, HD_B, 2, { 4, 5 })
    hl.active_window = "0x101"
    qs.focus_side(1)
    eq(last().arg, "address:0x102", "the master's right is the stack's top")
    hl.active_window = "0x103"
    qs.focus_side(1)
    eq(last().arg, "address:0x104", "the stack's right is B's master")
    hl.active_window = "0x104"
    qs.focus_side(-1)
    eq(last().arg, "address:0x102", "B's master's left is a window at A's right edge")
    local n = #hl.dispatched
    hl.active_window = "0x105"
    qs.focus_side(1)
    eq(#hl.dispatched, n, "past the last monitor, nothing")
    hl.active_window = "0x101"
    qs.focus_side(-1)
    eq(#hl.dispatched, n, "nor before the first")
end)

test("a monitor that way showing no windows, or a fullscreen one, takes focus itself", function()
    local qs, layout = two_monitors()
    lay(layout, HD, 1, { 1, 2 })
    hl.active_window = "0x102"
    qs.focus_side(1)
    eq(last().kind, "focus", "a focus")
    eq(last().monitor, "B", "monitor B")
    eq(last().arg, nil, "no window")
    lay(layout, HD_B, 2, { 3 })
    hl.monitors[2].has_fullscreen = true
    qs.focus_side(1)
    eq(last().monitor, "B", "the fullscreen window's monitor, not a tile behind it")
end)

test("with no window focused, Super+Right goes from the focused monitor", function()
    local qs, layout = two_monitors()
    lay(layout, HD_B, 2, { 4, 5 })
    hl.active_window = nil
    qs.focus_side(1)
    eq(last().arg, "address:0x104", "B's leftmost window")
end)

test("a scaled monitor's size is in layout coordinates", function()
    local qs, layout = fresh()
    -- A 2880x1800 panel at 2x is 1440 wide, so B starts at 1440.
    hl.monitors = {
        { name = "A", x = 0, y = 0, width = 2880, height = 1800, scale = 2, ws = 1, focused = true },
        { name = "B", x = 1440, y = 0, width = 1920, height = 1080, ws = 2 },
    }
    lay(layout, { x = 0, y = 34, w = 1440, h = 866 }, 1, { 1 })
    lay(layout, { x = 1440, y = 34, w = 1920, h = 1046 }, 2, { 2 })
    hl.active_window = "0x101"
    qs.focus_side(1)
    eq(last().arg, "address:0x102", "B is to the right")
end)

test("Super+Shift+Left and Right swap on the monitor, stopping past the last", function()
    local qs, layout = two_monitors()
    lay(layout, HD, 1, { 1, 2, 3 })
    hl.active_window = "0x103"
    qs.move_side(-1)
    eq(last().kind, "swap", "a swap")
    eq(last().arg, "address:0x101", "with the master")
    local n = #hl.dispatched
    hl.active_window = "0x101"
    qs.move_side(-1)
    eq(#hl.dispatched, n, "nothing left of the first monitor")
end)

test("at the edge the window goes onto the next monitor, landing at the edge it came in by", function()
    local qs, layout = two_monitors()
    lay(layout, HD, 1, { 1, 2, 3 })
    lay(layout, HD_B, 2, { 4, 5 })
    hl.active_window = "0x103"
    qs.move_side(1)
    eq(last().kind, "move", "a move")
    eq(last().monitor, "B", "to B")
    eq(last().follow, true, "keeping focus")
    -- Hyprland relayouts both workspaces, B's with the window at the end.
    lay(layout, HD, 1, { 1, 2 })
    local t = lay(layout, HD_B, 2, { 4, 5, 3 })
    eq(order_of(qs, 2), "0x103 0x104 0x105", "the master, on B's left")
    eq(t[3].placed.x, 1920, "at B's left edge")
end)

test("moving left onto a monitor lands in its stack at the height it left", function()
    local qs, layout = two_monitors()
    hl.monitors[1].focused, hl.monitors[2].focused = false, true
    lay(layout, HD, 1, { 1, 2, 3 })
    lay(layout, HD_B, 2, { 4, 5 })
    hl.active_window = "0x104"
    qs.move_side(-1)
    eq(last().monitor, "A", "to A")
    lay(layout, HD_B, 2, { 5 })
    lay(layout, HD, 1, { 1, 2, 3, 4 })
    -- B's master was full height, so it ties every stack place on height,
    -- and the first of them is the top.
    eq(order_of(qs, 1), "0x101 0x104 0x102 0x103", "the top of A's stack, on its right")
end)

test("a moved window that lands elsewhere goes where new windows go", function()
    local qs, layout = two_monitors()
    lay(layout, HD, 1, { 1, 2 })
    lay(layout, HD_B, 2, { 4 })
    hl.active_window = "0x102"
    qs.move_side(1)
    -- It arrived on workspace 3 instead, and later B's gets a new window.
    lay(layout, HD, 3, { 2 })
    lay(layout, HD_B, 2, { 4, 2 })
    eq(order_of(qs, 2), "0x104 0x102", "the end of the stack, as new_window says")
end)

-- A floating window on A, focused, with B showing workspace 2. Both
-- monitors reserve 34 px for the bar.
local function float_on_a(qs, layout, at, size)
    for _, m in ipairs(hl.monitors) do
        m.reserved = { top = 34, right = 0, bottom = 0, left = 0 }
    end
    lay(layout, HD, 1, { 1 })
    hl.windows = { { address = "0x1ff", workspace = { id = 1 }, mapped = true, floating = true,
        at = at, size = size } }
    lay(layout, HD_B, 2, { 4 })
    hl.active_window = "0x1ff"
end

-- The floating moves since dispatch `n`: the monitor move, any resize,
-- and the move to its place.
local function float_moves(n)
    local out = {}
    for i = n + 1, #hl.dispatched do
        out[#out + 1] = hl.dispatched[i]
    end
    return out
end

test("a floating window goes onto the next monitor at the same spot, keeping focus", function()
    local qs, layout = two_monitors()
    float_on_a(qs, layout, { x = 96, y = 86 }, { x = 400, y = 300 })
    local n = #hl.dispatched
    qs.move_side(1)
    local d = float_moves(n)
    eq(#d, 2, "a monitor move and a move, no resize")
    eq(d[1].kind, "move", "a move")
    eq(d[1].monitor, "B", "to B")
    eq(d[1].follow, true, "keeping focus")
    eq(d[1].window, "address:0x1ff", "the float")
    eq(d[2].x, 2016, "the same spot across B")
    eq(d[2].y, 86, "and down it")
    eq(d[2].window, "address:0x1ff", "the float")
    eq(d[2].monitor, nil, "a move to a place, not a monitor")
    n = #hl.dispatched
    hl.active_window = "0x1ff"
    hl.windows[1].at = { x = 0, y = 34 }
    qs.move_side(-1)
    eq(#hl.dispatched, n, "nothing left of the first monitor")
    qs.focus_side(1)
    eq(last().arg, "address:0x101", "focus still goes on from it")
end)

test("a floating window keeps its relative spot on a smaller monitor", function()
    local qs, layout = two_monitors()
    -- B is half A's size, below the same bar.
    hl.monitors[2].width, hl.monitors[2].height = 960, 557
    float_on_a(qs, layout, { x = 96, y = 86 }, { x = 400, y = 300 })
    local n = #hl.dispatched
    qs.move_side(1)
    local d = float_moves(n)
    eq(d[#d].x, 1968, "top left: a twentieth across B")
    eq(d[#d].y, 60, "and a twentieth down")
    hl.monitors[1].focused, hl.monitors[2].focused = true, false
    float_on_a(qs, layout, { x = 1420, y = 680 }, { x = 500, y = 400 })
    n = #hl.dispatched
    qs.move_side(1)
    d = float_moves(n)
    eq(#d, 2, "it fits, so no resize")
    eq(d[2].x, 1920 + 960 - 500, "bottom right: held at B's right edge")
    eq(d[2].y, 557 - 400, "and its bottom")
end)

test("a floating window too big for the next monitor shrinks to fit inside it", function()
    local qs, layout = two_monitors()
    hl.monitors[2].width, hl.monitors[2].height = 960, 557
    float_on_a(qs, layout, { x = 100, y = 100 }, { x = 1200, y = 600 })
    local n = #hl.dispatched
    qs.move_side(1)
    local d = float_moves(n)
    eq(#d, 3, "a monitor move, a resize and a move")
    eq(d[2].kind, "resize", "the resize before the move")
    eq(d[2].x, 960, "B's work area wide")
    eq(d[2].y, 523, "and tall")
    eq(d[3].x, 1920, "at its left")
    eq(d[3].y, 34, "below the bar")
end)

test("a floating window doesn't go to a monitor showing no workspace", function()
    local qs, layout = two_monitors()
    float_on_a(qs, layout, { x = 96, y = 86 }, { x = 400, y = 300 })
    hl.monitors[2].ws = nil
    local n = #hl.dispatched
    qs.move_side(1)
    eq(#hl.dispatched, n, "nothing")
end)

test("Hyprland's monitors or windows that can't be read do nothing", function()
    local qs, layout = two_monitors()
    lay(layout, HD, 1, { 1, 2 })
    hl.active_window = "0x101"
    hl.get_monitors = function()
        error("going away")
    end
    local n = #hl.dispatched
    qs.focus_side(1)
    qs.move_side(1)
    eq(#hl.dispatched, n, "nothing")
end)

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
