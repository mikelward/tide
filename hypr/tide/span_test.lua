-- Tests for span.lua, with made-up monitors. Plain Lua (5.4 or 5.5), no
-- dependencies: `lua hypr/tide/span_test.lua` from the repo root.

local dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local span = dofile(dir .. "span.lua")

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

-- A list of tables as one line, for comparing.
local function show(list)
    local out = {}
    for _, t in ipairs(list) do
        local keys = {}
        for k in pairs(t) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. "=" .. tostring(t[k])
        end
        out[#out + 1] = "{" .. table.concat(parts, " ") .. "}"
    end
    return table.concat(out, " ")
end

local function win(address, workspace)
    return { address = address, workspace = workspace }
end

test("the main monitor's part keeps the plain name", function()
    eq(span.part("re", "eDP-1", "eDP-1"), "re")
    eq(span.part("re", "DP-2", "eDP-1"), "re@DP-2")
end)

test("a part's name splits back into the workspace and its monitor", function()
    local name, output = span.split("re@DP-2")
    eq(name, "re")
    eq(output, "DP-2")
    name, output = span.split("re")
    eq(name, "re")
    eq(output, nil)
end)

test("a special workspace is no part of any workspace", function()
    eq(span.split("special:minimized"), nil)
    eq(span.output_of("special:minimized", "eDP-1"), nil)
    eq(span.split(""), nil)
    eq(span.split(nil), nil)
end)

test("a plain name is the main monitor's part", function()
    eq(span.output_of("re", "eDP-1"), "eDP-1")
    eq(span.output_of("re@DP-2", "eDP-1"), "DP-2")
end)

test("a name with spaces and a connector with digits round-trip", function()
    local hypr = span.part("tax return", "HDMI-A-1", "eDP-1")
    local name, output = span.split(hypr)
    eq(name, "tax return")
    eq(output, "HDMI-A-1")
end)

test("rules bind every part to its monitor, the main one's too", function()
    eq(show(span.rules("re", { "eDP-1", "DP-2", "DP-3" }, "eDP-1")),
        "{monitor=eDP-1 workspace=name:re} {monitor=DP-2 workspace=name:re@DP-2} {monitor=DP-3 workspace=name:re@DP-3}")
end)

test("a new main monitor takes the plain part's rule", function()
    eq(show(span.rules("re", { "DP-1", "DP-2" }, "DP-1")),
        "{monitor=DP-1 workspace=name:re} {monitor=DP-2 workspace=name:re@DP-2}")
end)

test("a switch shows every monitor's part, the focused monitor's last", function()
    eq(show(span.switch("re", { "eDP-1", "DP-2" }, "eDP-1", "eDP-1")),
        "{output=DP-2 workspace=name:re@DP-2} {output=eDP-1 workspace=name:re}")
    eq(show(span.switch("re", { "eDP-1", "DP-2" }, "eDP-1", "DP-2")),
        "{output=eDP-1 workspace=name:re} {output=DP-2 workspace=name:re@DP-2}")
end)

test("a switch on one monitor is the plain switch it always was", function()
    eq(show(span.switch("re", { "eDP-1" }, "eDP-1", "eDP-1")), "{output=eDP-1 workspace=name:re}")
end)

test("unplugging a display moves its windows into the main monitor's parts", function()
    local homes = {}
    local before = { win("a", "re"), win("b", "re@DP-2"), win("c", "in@DP-2") }
    eq(show(span.handoff(homes, before, { "eDP-1", "DP-2" }, "eDP-1")), "", "nothing moves while both are there")
    -- DP-2 goes; Hyprland moves its workspaces to eDP-1, names unchanged.
    eq(show(span.handoff(homes, before, { "eDP-1" }, "eDP-1")),
        "{address=b workspace=name:re} {address=c workspace=name:in}")
end)

test("plugging it back in returns each window to its part", function()
    local homes = {}
    local outputs = { "eDP-1", "DP-2" }
    span.handoff(homes, { win("a", "re"), win("b", "re@DP-2") }, outputs, "eDP-1")
    span.handoff(homes, { win("a", "re"), win("b", "re@DP-2") }, { "eDP-1" }, "eDP-1")
    -- While unplugged, b sits in eDP-1's part.
    eq(show(span.handoff(homes, { win("a", "re"), win("b", "re") }, outputs, "eDP-1")),
        "{address=b workspace=name:re@DP-2}")
end)

test("a window that moved workspace while unplugged returns on its new one", function()
    local homes = {}
    span.handoff(homes, { win("b", "re@DP-2") }, { "eDP-1", "DP-2" }, "eDP-1")
    eq(show(span.handoff(homes, { win("b", "oc") }, { "eDP-1", "DP-2" }, "eDP-1")),
        "{address=b workspace=name:oc@DP-2}")
end)

test("closing the lid makes the external display main, and opening it sorts them out", function()
    local homes = {}
    -- The panel is main, with a window on each monitor.
    span.handoff(homes, { win("p", "re"), win("x", "re@DP-1") }, { "eDP-1", "DP-1" }, "eDP-1")
    -- Lid closed: Hyprland moves the plain parts to DP-1, which now shows
    -- them, so DP-1 is main; x moves into the plain part beside p.
    eq(show(span.handoff(homes, { win("p", "re"), win("x", "re@DP-1") }, { "DP-1" }, "DP-1")),
        "{address=x workspace=name:re}")
    -- A window opened with the lid closed belongs on DP-1.
    local closed = { win("p", "re"), win("x", "re"), win("n", "re") }
    eq(show(span.handoff(homes, closed, { "DP-1" }, "DP-1")), "")
    -- Lid open: Hyprland returns the plain parts to the panel, main again,
    -- carrying x and n, which go back to DP-1's part.
    eq(show(span.handoff(homes, closed, { "eDP-1", "DP-1" }, "eDP-1")),
        "{address=x workspace=name:re@DP-1} {address=n workspace=name:re@DP-1}")
end)

test("a window moved to another monitor on purpose belongs there", function()
    local homes = {}
    local outputs = { "eDP-1", "DP-2" }
    span.handoff(homes, { win("a", "re") }, outputs, "eDP-1")
    span.moved(homes, "a", "DP-2")
    eq(show(span.handoff(homes, { win("a", "re@DP-2") }, outputs, "eDP-1")), "")
    span.handoff(homes, { win("a", "re@DP-2") }, { "eDP-1" }, "eDP-1")
    eq(show(span.handoff(homes, { win("a", "re") }, outputs, "eDP-1")),
        "{address=a workspace=name:re@DP-2}")
end)

test("a closed window is forgotten", function()
    local homes = {}
    span.handoff(homes, { win("a", "re@DP-2") }, { "eDP-1", "DP-2" }, "eDP-1")
    span.closed(homes, "a")
    eq(homes.a, nil)
end)

test("a window first seen in a part whose monitor is gone goes to the main monitor", function()
    local homes = {}
    eq(show(span.handoff(homes, { win("a", "re@DP-2") }, { "eDP-1" }, "eDP-1")),
        "{address=a workspace=name:re}")
    eq(homes.a, nil, "its home isn't guessed")
end)

test("a minimized window is left alone", function()
    local homes = {}
    eq(show(span.handoff(homes, { win("m", "special:minimized") }, { "eDP-1" }, "eDP-1")), "")
end)

io.write(string.format("span_test.lua: %d passed, %d failed\n", passed, failures))
os.exit(failures == 0 and 0 or 1)
