-- Tests for direction.lua, with made-up monitors. Plain Lua (5.4 or 5.5),
-- no dependencies: `lua hypr/tide/direction_test.lua` from the repo root.

local dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local direction = dofile(dir .. "direction.lua")

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

local function box(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
end

local function tile(address, x, y, w, h)
    return { address = address, box = box(x, y, w, h) }
end

-- Two 1920x1080 monitors side by side, each in tile: a master and two in
-- the stack on the left one, a master and one on the right.
local function pair()
    return {
        { name = "A", box = box(0, 0, 1920, 1080), tiles = {
            tile("a1", 0, 0, 1056, 1080), tile("a2", 1056, 0, 864, 540), tile("a3", 1056, 540, 864, 540),
        } },
        { name = "B", box = box(1920, 0, 1920, 1080), tiles = {
            tile("b1", 1920, 0, 1056, 1080), tile("b2", 2976, 0, 864, 1080),
        } },
    }
end

test("left and right pick the window that way on the same monitor", function()
    local m = pair()
    local hit, mon = direction.find(m[1].tiles[1].box, "A", m, 1)
    eq(hit.address, "a2", "the master's right: the first of two sharing its height")
    eq(mon.name, "A", "same monitor")
    hit = direction.find(m[1].tiles[3].box, "A", m, -1)
    eq(hit.address, "a1", "the stack's left is the master")
end)

test("at a monitor's edge they go on to the nearest window on the next one", function()
    local m = pair()
    local hit, mon = direction.find(m[1].tiles[3].box, "A", m, 1)
    eq(mon.name, "B", "next monitor")
    eq(hit.address, "b1", "its leftmost window, sharing the most height")
    hit, mon = direction.find(m[2].tiles[1].box, "B", m, -1)
    eq(mon.name, "A", "back")
    eq(hit.address, "a2", "a window at A's right edge, not the taller master behind them")
end)

test("past the last monitor, nothing", function()
    local m = pair()
    local hit, mon = direction.find(m[2].tiles[2].box, "B", m, 1)
    eq(hit, nil, "no window")
    eq(mon, nil, "no monitor")
    hit, mon = direction.find(m[1].tiles[1].box, "A", m, -1)
    eq(mon, nil, "none to the left either")
end)

test("a monitor that way with no windows is picked with no window", function()
    local m = pair()
    m[2].tiles = {}
    local hit, mon = direction.find(m[1].tiles[2].box, "A", m, 1)
    eq(hit, nil, "no window")
    eq(mon.name, "B", "the monitor itself")
end)

test("the next monitor is the one sharing the most height, then the nearest", function()
    -- A laptop panel, with two monitors stacked on its right, the lower
    -- one sharing more of its height.
    local m = {
        { name = "L", box = box(0, 600, 1920, 1200), tiles = { tile("l1", 0, 600, 1920, 1200) } },
        { name = "U", box = box(1920, 0, 1920, 1080), tiles = { tile("u1", 1920, 0, 1920, 1080) } },
        { name = "D", box = box(1920, 1080, 1920, 1080), tiles = { tile("d1", 1920, 1080, 1920, 1080) } },
    }
    local hit, mon = direction.find(m[1].tiles[1].box, "L", m, 1)
    eq(mon.name, "D", "720 px shared beats 480")
    eq(hit.address, "d1", "its window")
end)

test("a window there whose center is back past yours still counts", function()
    -- A narrow window at the far right of A, and a wide one on B whose
    -- center is still right of it.
    local m = {
        { name = "A", box = box(0, 0, 1000, 1000), tiles = { tile("a1", 900, 0, 100, 1000) } },
        { name = "B", box = box(1000, 0, 100, 1000), tiles = { tile("b1", 1000, 0, 100, 1000) } },
    }
    local hit = direction.find(m[1].tiles[1].box, "A", m, 1)
    eq(hit.address, "b1", "picked on the next monitor")
end)

test("an unknown monitor finds nothing", function()
    eq(direction.find(box(0, 0, 1, 1), "Z", pair(), 1), nil, "nothing")
end)

test("a window lands at the edge it came in by, sharing the most height", function()
    -- Tile on B with three windows once it's there: master left, two in
    -- the stack right.
    local slots = { box(1920, 0, 1056, 1080), box(2976, 0, 864, 540), box(2976, 540, 864, 540) }
    eq(direction.landing(slots, 1, box(1056, 540, 864, 540)), 1, "moving right lands as the master, on the left")
    eq(direction.landing(slots, -1, box(4000, 600, 500, 400)), 3, "moving left lands in the stack, at the height it left")
    eq(direction.landing(slots, -1, box(4000, 0, 500, 400)), 2, "or higher up")
end)

test("in monocle every place ties, so the first", function()
    local slots = { box(0, 0, 10, 10), box(0, 0, 10, 10) }
    eq(direction.landing(slots, 1, box(0, 0, 10, 10)), 1, "first")
    eq(direction.landing({}, 1, box(0, 0, 10, 10)), nil, "none with no places")
end)

test("the next monitor is the one that way, by the same rule", function()
    local m = pair()
    eq(direction.next_monitor(m[1], m, 1).name, "B", "right of A")
    eq(direction.next_monitor(m[2], m, -1).name, "A", "left of B")
    eq(direction.next_monitor(m[2], m, 1), nil, "none past the last")
end)

-- A float moving from a 1920x1046 work area to one half its size, below
-- the same 34 px bar.
local FROM, TO = box(0, 34, 1920, 1046), box(1920, 34, 960, 523)

test("a float in the top left lands in the top left", function()
    local b = direction.place(box(96, 86, 400, 300), FROM, TO)
    eq(b.x, 1968, "x: its offset, a twentieth across, scaled")
    eq(b.y, 60, "y: a twentieth down, scaled")
    eq(b.w, 400, "its width")
    eq(b.h, 300, "its height")
end)

test("a float in the bottom right lands in the bottom right", function()
    local b = direction.place(box(1420, 680, 500, 400), FROM, TO)
    eq(b.x + b.w, TO.x + TO.w, "at the right edge, held inside")
    eq(b.y + b.h, TO.y + TO.h, "at the bottom edge, held inside")
    eq(b.w, 500, "its width")
    eq(b.h, 400, "its height")
    -- Onto a monitor the same size, it's the same spot.
    local same = direction.place(box(1420, 680, 500, 400), FROM, box(1920, 34, 1920, 1046))
    eq(same.x, 3340, "the same offset")
    eq(same.y, 680, "the same height")
end)

test("a float too big for the next monitor shrinks to fit inside it", function()
    local b = direction.place(box(100, 100, 1200, 600), FROM, TO)
    eq(b.w, 960, "as wide as the work area")
    eq(b.h, 523, "as tall")
    eq(b.x, 1920, "at its left")
    eq(b.y, 34, "at its top")
    local wide = direction.place(box(800, 100, 1200, 300), FROM, TO)
    eq(wide.w, 960, "only the side too big shrinks")
    eq(wide.h, 300, "the other keeps its size")
    eq(wide.y, 34 + math.floor(66 / 1046 * 523 + 0.5), "and its relative spot")
end)

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
