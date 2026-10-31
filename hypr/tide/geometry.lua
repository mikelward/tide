-- Window geometry for the tide layouts (SPEC.md §6), kept free of any
-- Hyprland API so it can be tested with plain Lua.
--
-- Every function takes the work area as a box {x, y, w, h} and returns one
-- box per tiled window, in window order: masters first, then the stack.
-- Boxes are on whole pixels and neighbors share an edge, so the tiles cover
-- the area exactly with no gaps and no overlap.

local M = {}

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end
M.clamp = clamp

-- Cut [start, start + len) into pieces weighted by `weights`, on integer
-- edges. Rounding each edge rather than each size keeps the pieces
-- contiguous and their total exactly `len`.
local function spans(start, len, weights)
    local total = 0
    for _, wt in ipairs(weights) do
        total = total + wt
    end
    local out = {}
    local acc = 0
    local prev = math.floor(start + 0.5)
    for i, wt in ipairs(weights) do
        acc = acc + wt
        local edge = math.floor(start + len * acc / total + 0.5)
        out[i] = { pos = prev, size = edge - prev }
        prev = edge
    end
    return out
end

local function equal(n)
    local w = {}
    for i = 1, n do
        w[i] = 1
    end
    return w
end

-- Boxes for columns across `area`, weighted by `weights`.
function M.columns(area, weights)
    local boxes = {}
    local ys = spans(area.y, area.h, { 1 })[1]
    for i, s in ipairs(spans(area.x, area.w, weights)) do
        boxes[i] = { x = s.pos, y = ys.pos, w = s.size, h = ys.size }
    end
    return boxes
end

-- `n` equal rows down `area`.
function M.rows(area, n)
    local boxes = {}
    local xs = spans(area.x, area.w, { 1 })[1]
    for i, s in ipairs(spans(area.y, area.h, equal(n))) do
        boxes[i] = { x = xs.pos, y = s.pos, w = xs.size, h = s.size }
    end
    return boxes
end

local function append(dst, src)
    for _, b in ipairs(src) do
        dst[#dst + 1] = b
    end
    return dst
end

-- The width fraction for a lone window. `rules` is a list of
-- {min_aspect = a, width = f}; the rule with the largest min_aspect that the
-- area's aspect ratio reaches wins, and nothing matching means full width.
function M.single_width(area, rules)
    local aspect = area.h > 0 and area.w / area.h or 0
    local best, width = -1, 1.0
    for _, r in ipairs(rules or {}) do
        if aspect >= r.min_aspect and r.min_aspect > best then
            best, width = r.min_aspect, r.width
        end
    end
    return clamp(width, 0.1, 1.0)
end

-- A lone window, centered at `single_width` of the area.
function M.single(area, rules)
    local f = M.single_width(area, rules)
    if f >= 1.0 then
        return M.columns(area, { 1 })
    end
    local side = (1 - f) / 2
    return { M.columns(area, { side, f, side })[2] }
end

-- Master column on the left, stack on the right (dwm "tile").
function M.tile(area, n, o)
    if n <= 0 then
        return {}
    end
    local m = clamp(o.nmaster or 1, 0, n)
    if m == 0 or m == n then
        return M.rows(area, n)
    end
    local cols = M.columns(area, { o.mfact, 1 - o.mfact })
    return append(M.rows(cols[1], m), M.rows(cols[2], n - m))
end

-- Master centered with a stack either side. With a single stack window
-- there is nothing to balance, so it is master + one column. Stack windows
-- alternate right, left, right... so adding one never moves the others to
-- the other side.
function M.threecol(area, n, o)
    if n <= 0 then
        return {}
    end
    local m = clamp(o.nmaster or 1, 1, n)
    local s = n - m
    if s == 0 then
        return M.rows(area, n)
    end
    if s == 1 then
        local cols = M.columns(area, { o.mfact, 1 - o.mfact })
        return append(M.rows(cols[1], m), { cols[2] })
    end
    local side = (1 - o.mfact) / 2
    local cols = M.columns(area, { side, o.mfact, side })
    local nright = math.ceil(s / 2)
    local right = M.rows(cols[3], nright)
    local left = M.rows(cols[1], s - nright)
    local boxes = M.rows(cols[2], m)
    local r, l = 0, 0
    for k = 1, s do
        if k % 2 == 1 then
            r = r + 1
            boxes[#boxes + 1] = right[r]
        else
            l = l + 1
            boxes[#boxes + 1] = left[l]
        end
    end
    return boxes
end

-- Masters as full-height columns side by side, the rest stacked on the
-- right. With no stack the masters share the whole width.
function M.twocol(area, n, o)
    if n <= 0 then
        return {}
    end
    local m = clamp(o.nmaster or 2, 1, n)
    if m == n then
        return M.columns(area, equal(n))
    end
    local weights = {}
    for i = 1, m do
        weights[i] = o.mfact / m
    end
    weights[m + 1] = 1 - o.mfact
    local cols = M.columns(area, weights)
    local boxes = {}
    for i = 1, m do
        boxes[i] = cols[i]
    end
    return append(boxes, M.rows(cols[m + 1], n - m))
end

-- Every window fills the area; the focused one is on top.
function M.monocle(area, n)
    local boxes = {}
    for i = 1, n do
        boxes[i] = M.columns(area, { 1 })[1]
    end
    return boxes
end

M.modes = { "tile", "threecol", "twocol", "monocle" }

-- mfact's range, which the layout's mfact layoutmsg clamps to as well.
M.mfact_min, M.mfact_max = 0.1, 0.9

-- The split edges a pointer can drag in `mode` with `n` windows: vertical
-- lines down the whole area, each `{ x = ..., kind = ... }` with x the
-- first pixel right of the edge. Dragging one changes mfact:
--   "left"   the master side spans from the area's left edge to x (tile,
--            twocol, threecol with one stack window);
--   "center" the master is centered, x is one of its sides (`side`,
--            "left" or "right"), and it grows both ways (threecol with
--            stacks either side).
-- Rows within a column are always equal, with no per-window weight to
-- drag, and twocol's masters split their side equally, so neither has an
-- edge here. A lone window and monocle have none either.
function M.split_edges(mode, area, n, o)
    if n < 2 or o == nil or o.mfact == nil then
        return {}
    end
    if mode == "tile" then
        local m = clamp(o.nmaster or 1, 0, n)
        if m == 0 or m == n then
            return {}
        end
        return { { x = M.columns(area, { o.mfact, 1 - o.mfact })[2].x, kind = "left" } }
    elseif mode == "threecol" then
        local s = n - clamp(o.nmaster or 1, 1, n)
        if s == 0 then
            return {}
        elseif s == 1 then
            return { { x = M.columns(area, { o.mfact, 1 - o.mfact })[2].x, kind = "left" } }
        end
        local side = (1 - o.mfact) / 2
        local cols = M.columns(area, { side, o.mfact, side })
        return { { x = cols[2].x, kind = "center", side = "left" }, { x = cols[3].x, kind = "center", side = "right" } }
    elseif mode == "twocol" then
        local m = clamp(o.nmaster or 2, 1, n)
        if m == n then
            return {}
        end
        -- twocol's own weights, so the edge rounds as its boxes do.
        local weights = {}
        for i = 1, m do
            weights[i] = o.mfact / m
        end
        weights[m + 1] = 1 - o.mfact
        return { { x = M.columns(area, weights)[m + 1].x, kind = "left" } }
    end
    return {}
end

-- The edge of `edges` whose grab zone holds the point (x, y): `grab`
-- pixels either side of it, down the area's height. nil if none does.
function M.edge_at(edges, area, x, y, grab)
    if grab <= 0 or y < area.y or y >= area.y + area.h then
        return nil
    end
    for _, e in ipairs(edges) do
        if x >= e.x - grab and x < e.x + grab then
            return e
        end
    end
end

-- The mfact that puts `edge` at x, clamped to mfact's range. A centered
-- master's side keeps its own direction: dragged past the center, it
-- holds the master at its narrowest rather than growing it again.
function M.drag_mfact(edge, area, x)
    if area.w <= 0 then
        return nil
    end
    local f
    if edge.kind == "center" then
        local from_center = x - (area.x + area.w / 2)
        if edge.side == "left" then
            from_center = -from_center
        end
        f = 2 * from_center / area.w
    else
        f = (x - area.x) / area.w
    end
    return clamp(f, M.mfact_min, M.mfact_max)
end

-- Whether the point (x, y) is inside `box`, or within `pad` pixels of it.
function M.contains(box, x, y, pad)
    pad = pad or 0
    return x >= box.x - pad and x < box.x + box.w + pad and y >= box.y - pad and y < box.y + box.h + pad
end

-- The smallest box holding every box of `boxes`, or nil if there are none.
-- The tiles of two or more windows cover the work area exactly, so theirs
-- is the area they were laid out in.
function M.bounds(boxes)
    local x0, y0, x1, y1
    for _, b in ipairs(boxes) do
        x0 = x0 and math.min(x0, b.x) or b.x
        y0 = y0 and math.min(y0, b.y) or b.y
        x1 = x1 and math.max(x1, b.x + b.w) or b.x + b.w
        y1 = y1 and math.max(y1, b.y + b.h) or b.y + b.h
    end
    if x0 then
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
end

-- Boxes for `n` windows in `mode`. A lone window follows the single-window
-- rule in every mode.
function M.arrange(mode, area, n, o, single_rules)
    if n == 1 then
        return M.single(area, single_rules)
    end
    local f = M[mode]
    if type(f) ~= "function" then
        error("unknown layout mode: " .. tostring(mode))
    end
    return f(area, n, o or {})
end

return M
