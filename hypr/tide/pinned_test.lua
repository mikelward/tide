-- Tests for pinned.lua (SPEC.md §6.5). Plain Lua (5.4 or 5.5):
-- `lua hypr/tide/pinned_test.lua` from the repo root. pinned.lua runs
-- against a stub of the Hyprland `hl` API that records its dispatches,
-- commands and notifications.

local dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"

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

local S

local function load()
    S = { dispatched = {}, execs = {}, notified = {}, active = nil }
    _G.hl = {
        dispatch = function(d) table.insert(S.dispatched, d) end,
        exec_cmd = function(c) table.insert(S.execs, c) end,
        get_active_window = function()
            if S.active == "raise" then
                error("window gone")
            end
            return S.active
        end,
        notification = { create = function(n) table.insert(S.notified, n) end },
        dsp = { window = { close = function(a) return { dsp = "window.close", args = a } end } },
    }
    local m = dofile(dir .. "pinned.lua")
    m.set({
        { workspace = "in", classes = { "gmail", "org.example.Calendar" }, sites = { "google.com" } },
        { workspace = "re", classes = { "kitty" } },
    })
    return m
end

local function window(class, workspace)
    return { class = class, workspace = { name = workspace }, address = "0x1" }
end

test("a pinned app's window on its workspace is pinned there", function()
    local m = load()
    eq(m.pinned_on(window("gmail", "in")), "in", "its class")
    eq(m.pinned_on(window("GMail.desktop", "IN")), "IN", "ignoring case and .desktop")
    eq(m.pinned_on(window("com.example.gmail", "in")), "in", "a bare name is a qualified class's last part")
    eq(m.pinned_on(window("org.example.calendar", "in")), "in", "a qualified name in full")
    eq(m.pinned_on(window("net.example.Calendar", "in")), nil, "but no other qualified one")
    eq(m.pinned_on(window("chrome-mail.google.com__-Default", "in")), "in", "a site's --app window, subdomains too")
    eq(m.pinned_on(window("chromium-google.com__mail_-Profile_1", "in")), "in", "in Chromium, any profile")
    eq(m.pinned_on(window("chrome-notgoogle.com__-Default", "in")), nil, "not another site that ends the same")
    eq(m.pinned_on(window("gmail", "in@DP-2")), "in", "on another monitor's part of it")
    eq(m.pinned_on(window("gmail", "re")), nil, "not on another workspace")
    eq(m.pinned_on(window("gmail", "special:minimized:in")), "in", "minimized from it")
    eq(m.pinned_on(window("gmail", "special:minimized:in@DP-2")), "in", "minimized from another monitor's part")
    eq(m.pinned_on(window("gmail", "special:scratch")), nil, "not on another special workspace")
    eq(m.pinned_on(window("firefox", "in")), nil, "not an app that isn't pinned")
    eq(m.pinned_on(window(nil, "in")), nil, "not a window with no class")
    eq(m.pinned_on(nil), nil)
end)

test("Super+Backspace closes a window that isn't pinned, and refuses one that is, saying why", function()
    local m = load()
    S.active = window("firefox", "in")
    m.close()
    eq(#S.dispatched, 1)
    eq(S.dispatched[1].dsp, "window.close", "an unpinned window closes")
    eq(#S.execs, 0, "silently")
    S.dispatched = {}
    S.active = window("gmail", "in")
    eq(m.close(), nil, "the key goes no further")
    eq(#S.dispatched, 0, "a pinned one doesn't close")
    eq(#S.execs, 1)
    eq(S.execs[1], "notify-send --app-name=tide 'Pinned window' 'It'\\''s pinned on in, so it stays open.'", "a notification says so")
    S.active = nil
    m.close()
    eq(S.dispatched[1].dsp, "window.close", "with nothing focused, it's Hyprland's close, as before")
end)

test("an app's close keys reach every window but a pinned one", function()
    local m = load()
    S.active = window("firefox", "in")
    local r = m.shortcut()
    eq(type(r) == "table" and r.pass_event, true, "an unpinned window gets the key")
    eq(#S.execs, 0)
    S.active = window("kitty", "re")
    eq(m.shortcut(), nil, "a pinned one doesn't")
    eq(#S.dispatched, 0, "and nothing closes")
    eq(S.execs[1]:find("pinned on re", 1, true) ~= nil, true, "a notification says why")
    S.active = window("kitty", "in")
    eq(m.shortcut().pass_event, true, "kitty is pinned on re, not in")
    S.active = nil
    eq(m.shortcut().pass_event, true, "with nothing focused, the key goes on")
    eq(m.shortcuts[1], "CTRL + W")
    eq(#m.shortcuts, 4, "Ctrl+W, Ctrl+Shift+W, Ctrl+Q and Alt+F4")
end)

test("a window that can't be read is reported, and the key does what it would unpinned", function()
    local m = load()
    S.active = "raise"
    eq(m.shortcut().pass_event, true)
    m.close()
    eq(S.dispatched[1].dsp, "window.close")
    eq(#S.notified, 2)
    eq(S.notified[1].text:find("couldn't read the focused window", 1, true) ~= nil, true, S.notified[1].text)
end)

test("set() takes a new list whole, and refuses a wrong one naming what's wrong", function()
    local m = load()
    m.set({})
    eq(m.pinned_on(window("gmail", "in")), nil, "nothing pinned now")
    m.set(nil)
    m.set({ { workspace = "in", classes = { "gmail" } } })
    eq(m.pinned_on(window("gmail", "in")), "in", "sites may be left out")
    local cases = {
        { "x", "expected a list" },
        { { "in" }, "entry 1 should be a table" },
        { { { classes = {} } }, "entry 1 should name its workspace" },
        { { { workspace = "in", classes = "gmail" } }, "entry 1's classes should be a list" },
        { { { workspace = "in", sites = { "a", "" } } }, "entry 1's sites should list names, with no gaps; 2 is " },
    }
    for _, c in ipairs(cases) do
        local ok, err = pcall(m.set, c[1])
        eq(ok, false, c[2])
        eq(tostring(err):find(c[2], 1, true) ~= nil, true, tostring(err))
    end
    eq(m.pinned_on(window("gmail", "in")), "in", "a wrong list leaves the last good one")
end)

io.write(string.format("pinned_test.lua: %d passed, %d failed\n", passed, failures))
os.exit(failures == 0 and 0 or 1)
