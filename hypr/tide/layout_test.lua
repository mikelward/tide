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
            return { kind = "focus", arg = t.window }
        end,
        window = {
            swap = function(t)
                return { kind = "swap", arg = t.target }
            end,
        },
    }
    h.get_active_workspace = function()
        return { id = h.active_ws }
    end
    h.get_active_window = function()
        return h.active_window and { address = h.active_window } or nil
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
            window = { address = string.format("0x%x", 0x100 + i), workspace = { id = ws } },
            place = function(self, box)
                self.placed = box
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

local function fresh()
    hl = stub_hl()
    local qs = load_layout()
    qs.setup({})
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

local function relayout(layout, area, ws, n)
    local t = targets(ws, n)
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

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
