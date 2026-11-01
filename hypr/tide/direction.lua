-- Left and right between windows and monitors (SPEC.md §6.6): which window
-- Super+Left and Right select, where Super+Shift+Left and Right move the
-- window, and where a moved window lands on the next monitor. Pure geometry
-- on { x, y, w, h } boxes, with no Hyprland API, so it tests in plain Lua
-- with made-up monitors. tilemo's direction.lua is the same rule.
--
-- One rule picks both a window and a monitor: of the boxes on that side,
-- the one sharing the most height with where you are, then the one whose
-- center is nearest, then the first listed. "On that side" means its
-- center is left (d < 0) or right (d > 0) of yours.

local M = {}

local function center(b)
    return b.x + b.w / 2, b.y + b.h / 2
end

-- How many pixels of height two boxes share.
function M.overlap(a, b)
    return math.max(0, math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y))
end

-- Whether box `b` is on side `d` of box `from`.
function M.beside(from, b, d)
    local fx = center(from)
    local bx = center(b)
    return d < 0 and bx < fx or d > 0 and bx > fx
end

-- Of `items`, each { box = ... } plus whatever the caller keeps, the one
-- the rule picks against `from`, or nil with none.
function M.nearest(from, items)
    local fx, fy = center(from)
    local best, best_overlap, best_dist
    for _, it in ipairs(items) do
        local o = M.overlap(from, it.box)
        local x, y = center(it.box)
        local dist = (x - fx) ^ 2 + (y - fy) ^ 2
        if not best or o > best_overlap or (o == best_overlap and dist < best_dist) then
            best, best_overlap, best_dist = it, o, dist
        end
    end
    return best
end

-- The same, of the items on side `d` of `from` only.
function M.pick(from, items, d)
    local side = {}
    for _, it in ipairs(items) do
        if M.beside(from, it.box, d) then
            side[#side + 1] = it
        end
    end
    return M.nearest(from, side)
end

-- Of `items`, the ones nearest the edge you come in by going `d`: the
-- left edge going right, the right edge going left. A pixel's slack keeps
-- a column whose windows were rounded differently together.
function M.at_edge(items, d)
    local best
    for _, it in ipairs(items) do
        local e = d > 0 and it.box.x or -(it.box.x + it.box.w)
        best = best and math.min(best, e) or e
    end
    local out = {}
    for _, it in ipairs(items) do
        local e = d > 0 and it.box.x or -(it.box.x + it.box.w)
        if e <= best + 1 then
            out[#out + 1] = it
        end
    end
    return out
end

-- Where Super+Left or Right goes from `box` on monitor `here`. `monitors`
-- is every monitor, each { name, box, tiles }, its tiles each { address,
-- box }, in layout order. Returns the tile picked and its monitor: on this
-- monitor if one is that way; at its edge, on the next monitor that way,
-- at the edge you come in by and picked against `box` as well; nil for the
-- tile if that monitor has none; nil for both with no monitor that way.
function M.find(box, here, monitors, d)
    local cur
    for _, m in ipairs(monitors) do
        if m.name == here then
            cur = m
        end
    end
    if not cur then
        return nil
    end
    local hit = M.pick(box, cur.tiles, d)
    if hit then
        return hit, cur
    end
    local others = {}
    for _, m in ipairs(monitors) do
        if m.name ~= here then
            others[#others + 1] = { box = m.box, monitor = m }
        end
    end
    local next_one = M.pick(cur.box, others, d)
    if not next_one then
        return nil
    end
    local m = next_one.monitor
    -- The nearest window there is one at the edge you come in by. That
    -- monitor is the side test, so a tile there whose center is back past
    -- `box`'s still counts.
    return M.nearest(box, M.at_edge(m.tiles, d)), m
end

-- Where a window moved onto a monitor going `d` lands: of `slots`, the
-- boxes the layout would give each place in its order once the window is
-- there, the place nearest the edge it came in by (the left edge going
-- right, the right edge going left), then the one sharing the most height
-- with `from`, where the window was, then the first. Returns the place.
function M.landing(slots, d, from)
    local best, best_edge, best_overlap
    for i, b in ipairs(slots) do
        -- Smaller is nearer the edge it came in by.
        local edge = d > 0 and b.x or -(b.x + b.w)
        local o = M.overlap(from, b)
        if not best or edge < best_edge or (edge == best_edge and o > best_overlap) then
            best, best_edge, best_overlap = i, edge, o
        end
    end
    return best
end

return M
