-- Tests for focus.lua (SPEC.md §14.1). Plain Lua (5.4 or 5.5):
-- `lua hypr/tide/focus_test.lua` from the repo root. focus.lua runs
-- against a stub of the Hyprland `hl` API that records its rules, handlers
-- and dispatches, with a clock the tests drive.

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

-- Hyprland's focus reasons (eFocusReason, a plain enum).
local FFM, KEYBIND, DISPATCH, CLICK, WORKSPACE = 1, 2, 3, 5, 11
local UNMAP_TILING, UNMAP_FLOATING = 13, 14

local S -- what the stub recorded
local now

local function load(opts)
    S = { rules = {}, handlers = {}, dispatched = {}, notified = {}, active = nil, timers = {}, windows = {}, workspace = 1, logged = {} }
    now = 1000
    _G.tide_focus = nil
    _G.hl = {
        window_rule = function(r) table.insert(S.rules, r) end,
        on = function(ev, fn) S.handlers[ev] = fn end,
        dispatch = function(d) table.insert(S.dispatched, d) end,
        get_active_window = function() return S.active end,
        get_active_workspace = function() return { id = S.workspace } end,
        get_windows = function() return S.windows end,
        get_monitor_at_cursor = function() return nil end,
        timer = function(fn, opts) table.insert(S.timers, { fn = fn, opts = opts }) end,
        notification = {
            create = function(n) table.insert(S.notified, n) end,
        },
        dsp = {
            focus = function(a) return { dsp = "focus", args = a } end,
            event = function(e) return { dsp = "event", args = e } end,
            window = {
                move = function(a) return { dsp = "move", args = a } end,
            },
        },
    }
    local m = dofile(dir .. "focus.lua")
    m.clock = function() return now end
    m.log = function(line) table.insert(S.logged, line) end
    m.setup(opts)
    return m
end

local next_address = 0
local function window(class, pid)
    next_address = next_address + 1
    return { class = class, initial_class = class, pid = pid or next_address, address = string.format("0x%x", next_address) }
end

local function fire(ev, ...)
    S.dispatched = {}
    S.handlers[ev](...)
    return S.dispatched
end

-- Focus lands on w: the guard's dispatch, then Hyprland's window.active.
local function focused(w, reason)
    fire("window.active", w, reason)
end

local function is_focus(d, w)
    return d and d.dsp == "focus" and d.args.window == "address:" .. w.address
end

local function is_attention(d, w)
    return d and d.dsp == "event" and d.args == "tide-attention>>" .. w.address
end

test("every window opens unfocused, so a failing guard never steals", function()
    load()
    eq(#S.rules, 1, "rules")
    eq(S.rules[1].no_initial_focus, true, "no_initial_focus")
    eq(S.rules[1].match.class, ".*", "matches every window")
end)

test("setup publishes the module for tide launch", function()
    local m = load()
    eq(_G.tide_focus, m, "tide_focus")
end)

test("setup rejects an unknown or bad option", function()
    eq(pcall(load, { grant_secs = 5 }), false, "typo")
    eq(pcall(load, { grant_seconds = 0 }), false, "zero")
    eq(pcall(load, { grant_seconds = "10" }), false, "string")
    eq(pcall(load, { notify = "yes" }), false, "notify string")
    eq(pcall(load, { grant_seconds = 0 / 0 }), false, "grant_seconds NaN")
    eq(pcall(load, { prompt_seconds = 0 / 0 }), false, "prompt_seconds NaN")
    eq(pcall(load, { grant_seconds = math.huge }), false, "grant_seconds infinite")
    eq(pcall(load, { prompt_classes = "hyprpolkitagent" }), false, "prompt_classes string")
    eq(pcall(load, { portal_classes = { "" } }), false, "portal_classes empty class")
    eq(pcall(load, { prompt_classes = { 1 } }), false, "prompt_classes number")
    eq(pcall(load, { prompt_classes = { agent = "hyprpolkitagent" } }), false, "prompt_classes keyed")
    eq(pcall(load, { prompt_classes = { "a", nil, "c" } }), false, "prompt_classes sparse")
    local mutated = { "a", "b", "c", "d" }
    mutated[2] = nil
    mutated[6] = "e" -- four keys, and `#` may well say 4 too
    eq(pcall(load, { prompt_classes = mutated }), false, "prompt_classes mutated into gaps")
end)

test("ids normalize case and .desktop, and keep their namespace", function()
    local m = load()
    eq(m.normalize("org.gnome.Nautilus"), "org.gnome.nautilus")
    eq(m.normalize("Nautilus"), "nautilus")
    eq(m.normalize("nautilus.desktop"), "nautilus")
    eq(m.normalize(""), nil)
    eq(m.normalize(nil), nil)
end)

test("a bare name matches a qualified id; two namespaces don't", function()
    local m = load()
    eq(m.same_id("nautilus", "org.gnome.nautilus"), true, "bare to qualified")
    eq(m.same_id("org.gnome.nautilus", "nautilus"), true, "qualified to bare")
    eq(m.same_id("org.example.chat", "com.example.chat"), false, "namespaces")
    eq(m.same_id("kitty", "foot"), false, "different names")
end)

test("a grant for one namespace isn't used by another", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("org.example.Chat")
    local other = window("com.example.Chat")
    eq(is_attention(fire("window.open", other)[1], other), true, "announced")
    local ours = window("org.example.Chat")
    eq(is_focus(fire("window.open", ours)[1], ours), true, "focused")
end)

test("a new window from the app you're in takes focus", function()
    load()
    local kitty = window("kitty", 50)
    focused(kitty, FFM)
    local dialog = window("kitty", 50)
    local d = fire("window.open", dialog)
    eq(#d, 1, "dispatches")
    eq(is_focus(d[1], dialog), true, "focused")
end)

test("a status popup from the app you're in stays unfocused and unmarked", function()
    -- Chrome's own notification: no class and no title, from Chrome's
    -- process, shown inactive (SPEC.md §6.4).
    load()
    focused(window("google-chrome", 70), FFM)
    local popup = window("", 70)
    popup.title = ""
    eq(#fire("window.open", popup), 0, "no dispatch")
end)

test("a status popup takes no grant", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("*")
    local popup = window("", 71)
    popup.title = ""
    eq(#fire("window.open", popup), 0, "no dispatch")
    eq(m.grants()[1], "*", "the grant still holds")
    local app = window("org.example.app")
    eq(is_focus(fire("window.open", app)[1], app), true, "the next window uses it")
end)

test("a window with a title but no class is no status popup", function()
    load()
    focused(window("google-chrome", 72), FFM)
    local w = window("", 72)
    w.title = "Untitled"
    eq(is_focus(fire("window.open", w)[1], w), true, "focused")
end)

test("the same app by class counts even from another process", function()
    load()
    focused(window("org.gnome.Nautilus", 60), CLICK)
    local second = window("org.gnome.Nautilus", 61)
    eq(is_focus(fire("window.open", second)[1], second), true, "focused")
end)

test("a window from another app is left unfocused and announced", function()
    load()
    focused(window("kitty"), FFM)
    local popup = window("updater")
    local d = fire("window.open", popup)
    eq(#d, 1, "dispatches")
    eq(is_attention(d[1], popup), true, "announced")
end)

test("the first window of a launched app takes focus", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    local ff = window("firefox")
    eq(is_focus(fire("window.open", ff)[1], ff), true, "focused")
end)

test("a grant listing several classes is used by a window of any of them", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant({ "org.example.Editor", "example-editor" })
    eq(m.grants()[1], "org.example.editor example-editor", "listed with every class")
    local other = window("updater")
    eq(is_attention(fire("window.open", other)[1], other), true, "another app waits")
    local ours = window("example-editor")
    eq(is_focus(fire("window.open", ours)[1], ours), true, "the second class takes it")
    eq(#m.grants(), 0, "one grant, used up once")
end)

test("a list grant is rejected when empty, mixed with *, or holding a non-id", function()
    local m = load()
    eq(pcall(m.grant, {}), false, "empty")
    eq(pcall(m.grant, { "firefox", "*" }), false, "* beside a name")
    eq(pcall(m.grant, { "firefox", 3 }), false, "a number")
    eq(pcall(m.grant, { "firefox", "" }), false, "an empty id")
    eq(pcall(m.grant, { [2] = "firefox" }), false, "a gap")
    eq(#m.grants(), 0, "nothing recorded")
    m.grant({ "*" })
    eq(m.grants()[1], "*", "a lone * is a wildcard")
    local any = window("updater")
    eq(is_focus(fire("window.open", any)[1], any), true, "used by any app")
end)

test("a grant is used up even by the app you're in", function()
    local m = load()
    focused(window("kitty", 50), FFM)
    m.grant("kitty")
    fire("window.open", window("kitty", 50))
    eq(#m.grants(), 0, "used")
end)

test("a polkit prompt right after a key press takes focus", function()
    load()
    focused(window("kitty"), FFM)
    fire("input.keyboard.key", 28, 5000, 1) -- Enter on a pkexec line
    now = now + 1
    local prompt = window("hyprpolkitagent")
    eq(is_focus(fire("window.open", prompt)[1], prompt), true, "focused")
end)

test("a polkit prompt long after the last key press waits", function()
    load()
    focused(window("kitty"), FFM)
    fire("input.keyboard.key", 28, 5000, 1)
    now = now + 30 -- sleep 30; pkexec ...
    local prompt = window("hyprpolkitagent")
    eq(is_attention(fire("window.open", prompt)[1], prompt), true, "waits")
end)

test("the shell's agent may focus its prompt only right after a key press", function()
    local m = load()
    eq(m.prompt_may_focus(), false, "before any key")
    fire("input.keyboard.key", 28, 5000, 1)
    now = now + 2
    eq(m.prompt_may_focus(), true, "within prompt_seconds")
    now = now + 1
    eq(m.prompt_may_focus(), false, "after prompt_seconds")
    fire("input.keyboard.key", 28, 5000, 0) -- a release isn't a press
    eq(m.prompt_may_focus(), false, "after a release")
end)

test("prompt_seconds sets how recent the key press must be", function()
    local m = load({ prompt_seconds = 5 })
    fire("input.keyboard.key", 28, 5000, 1)
    now = now + 5
    eq(m.prompt_may_focus(), true, "within")
    now = now + 1
    eq(m.prompt_may_focus(), false, "after")
end)

test("a recent key press doesn't let other windows in", function()
    load()
    focused(window("kitty"), FFM)
    fire("input.keyboard.key", 28, 5000, 1)
    local popup = window("updater")
    eq(is_attention(fire("window.open", popup)[1], popup), true, "waits")
end)

-- A fake /proc: stat files naming each process's parent.
local function fake_proc(parents)
    local root = os.tmpname()
    os.remove(root)
    assert(os.execute("mkdir -p '" .. root .. "'"))
    for pid, ppid in pairs(parents) do
        assert(os.execute("mkdir -p '" .. root .. "/" .. pid .. "'"))
        local f = assert(io.open(root .. "/" .. pid .. "/stat", "w"))
        -- A command name with a space and a ')' in it, as a real one can have.
        f:write(pid .. " (my (app) x) S " .. ppid .. " 1 1 0\n")
        f:close()
    end
    return root
end

test("a window from a command the shell ran takes that shell's grant", function()
    local m = load()
    m.proc = fake_proc({ [300] = 200, [200] = 150 })
    focused(window("kitty", 100), FFM)
    m.grant("my-script", 150) -- from the preexec hook in shell 150
    local w = window("some-gui", 300)
    eq(is_focus(fire("window.open", w)[1], w), true, "focused")
    eq(#m.grants(), 0, "the grant is used up")
end)

test("a shell's grant is used even by a window of the app you're in", function()
    local m = load()
    m.proc = fake_proc({ [300] = 150 })
    focused(window("kitty", 100), FFM)
    m.grant("my-script", 150)
    fire("window.open", window("kitty", 300)) -- same app as the focused one
    eq(#m.grants(), 0, "used up")
end)

test("a command the shell exec'd takes that shell's grant", function()
    local m = load()
    m.proc = fake_proc({ [150] = 100 })
    focused(window("kitty", 100), FFM)
    m.grant("my-script", 150) -- `exec my-script` in shell 150
    local w = window("some-gui", 150) -- the shell's own pid, after exec
    eq(is_focus(fire("window.open", w)[1], w), true, "focused")
    eq(#m.grants(), 0, "the grant is used up")
end)

test("a grant with only a pid is for that shell's descendants", function()
    local m = load()
    m.proc = fake_proc({ [300] = 150, [400] = 100 })
    focused(window("kitty", 100), FFM)
    m.grant(nil, 150) -- a command whose app the shell can't name
    eq(m.grants()[1], "pid 150", "listed by pid")
    local other = window("some-gui", 400) -- from elsewhere
    eq(is_attention(fire("window.open", other)[1], other), true, "not by name")
    local w = window("some-gui", 300)
    eq(is_focus(fire("window.open", w)[1], w), true, "focused")
    eq(#m.grants(), 0, "the grant is used up")
end)

test("ancestry needs a grant from an ancestor", function()
    local m = load()
    m.proc = fake_proc({ [300] = 100 })
    focused(window("kitty", 100), FFM)
    local w = window("some-gui", 300)
    eq(is_attention(fire("window.open", w)[1], w), true, "no grant: waits")
    m.grant("firefox") -- a launch grant names no process
    local w2 = window("some-gui", 300)
    eq(is_attention(fire("window.open", w2)[1], w2), true, "launch grant: waits")
    eq(#m.grants(), 1, "the launch grant stays")
end)

test("a window from elsewhere doesn't take a shell's grant", function()
    local m = load()
    m.proc = fake_proc({ [300] = 250, [250] = 1 })
    focused(window("kitty", 100), FFM)
    m.grant("my-script", 150)
    local w = window("some-gui", 300)
    eq(is_attention(fire("window.open", w)[1], w), true, "waits")
    eq(#m.grants(), 1, "the grant stays")
end)

test("an unreadable /proc means no ancestry", function()
    local m = load()
    m.proc = "/nonexistent-proc"
    focused(window("kitty", 100), FFM)
    m.grant("my-script", 150)
    local w = window("some-gui", 300)
    eq(is_attention(fire("window.open", w)[1], w), true, "waits")
end)

test("grant rejects a bad process id", function()
    local m = load()
    eq(pcall(m.grant, "x", "150"), false, "string")
    eq(pcall(m.grant, "x", 1), false, "init")
    eq(pcall(m.grant, "x", 1.5), false, "fraction")
end)

test("a portal file chooser takes focus from the app you're in", function()
    load()
    focused(window("google-chrome"), CLICK)
    local chooser = window("xdg-desktop-portal-gtk")
    eq(is_focus(fire("window.open", chooser)[1], chooser), true, "focused")
end)

test("a portal dialog with nothing focused waits", function()
    load()
    local chooser = window("xdg-desktop-portal-gtk")
    eq(is_attention(fire("window.open", chooser)[1], chooser), true, "waits")
end)

test("a grant is used once", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    fire("window.open", window("firefox"))
    local second = window("firefox", 999)
    -- The grant went to the first window. Until focus actually lands there
    -- (window.active), kitty is still the app you're in, so a second firefox
    -- window is another app's.
    eq(is_attention(fire("window.open", second)[1], second), true, "second window announced")
end)

test("a wildcard grant is used by the next app's window, once", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("*")
    local chrome = window("google-chrome")
    eq(is_focus(fire("window.open", chrome)[1], chrome), true, "focused")
    local second = window("updater")
    eq(is_attention(fire("window.open", second)[1], second), true, "used up")
end)

test("a wildcard grant covers an activation too", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("*")
    local chrome = window("google-chrome")
    eq(is_focus(fire("window.urgent", chrome)[1], chrome), true, "focused")
end)

test("an activation before the window maps leaves the grant for its open", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("*")
    local chrome = window("google-chrome")
    chrome.mapped = false
    eq(#fire("window.urgent", chrome), 0, "neither focused nor announced")
    chrome.mapped = true
    eq(is_focus(fire("window.open", chrome)[1], chrome), true, "focused as it opens")
    eq(#S.notified, 0, "no notification")
end)

test("a mapped window's activation still uses the grant", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("*")
    local chrome = window("google-chrome")
    chrome.mapped = true
    eq(is_focus(fire("window.urgent", chrome)[1], chrome), true, "focused")
end)

test("a named grant is used before a wildcard", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("*")
    m.grant("firefox")
    fire("window.open", window("firefox"))
    eq(#m.grants(), 1, "one left")
    eq(m.grants()[1], "*", "the wildcard")
end)

test("a grant expires after grant_seconds", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    now = now + 11
    local ff = window("firefox")
    eq(is_attention(fire("window.open", ff)[1], ff), true, "late window announced")
    m.grant("chromium")
    now = now + 10
    local cr = window("chromium")
    eq(is_focus(fire("window.open", cr)[1], cr), true, "at exactly 10 s it still holds")
end)

test("grant_seconds is an option", function()
    local m = load({ grant_seconds = 3 })
    focused(window("kitty"), FFM)
    m.grant("firefox")
    now = now + 4
    local ff = window("firefox")
    eq(is_attention(fire("window.open", ff)[1], ff), true, "announced")
end)

test("extend widens a launch grant that still holds", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("editor", nil, 7)
    m.extend("editor", { "org.example.Editor", "editor", "example-editor-x11" }, nil, 7)
    eq(m.grants()[1], "editor org.example.editor example-editor-x11", "the names added once each")
    local w = window("org.example.Editor")
    eq(is_focus(fire("window.open", w)[1], w), true, "an added class takes it")
    eq(#m.grants(), 0, "used up")
end)

test("extend after a key press makes no grant", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("editor", nil, 7)
    fire("input.keyboard.key", 36, 5001, 1) -- you moved on while desktop entries were read
    m.extend("editor", { "org.example.Editor" }, nil, 7)
    eq(#m.grants(), 0, "still canceled")
    local w = window("org.example.Editor")
    eq(is_attention(fire("window.open", w)[1], w), true, "waits")
end)

test("extend widens a shell's grant by its pid, and only that one", function()
    local m = load()
    m.grant("nautilus", 150, 9) -- `nautilus .` in shell 150
    m.grant("nautilus", nil, 9) -- a launch
    m.extend("nautilus", { "org.gnome.Nautilus" }, 150, 9)
    eq(table.concat(m.grants(), ","), "nautilus org.gnome.nautilus,nautilus", "the shell's grant only")
    eq(pcall(m.extend, "nautilus", { "x" }, 1, 9), false, "pid 1 isn't a shell")
    eq(pcall(m.extend, "nautilus", { "x" }, "150", 9), false, "a pid is a number")
end)

test("extend leaves other grants alone and rejects bad ids", function()
    local m = load()
    m.grant("firefox")
    m.grant("*")
    m.extend("editor", { "org.example.Editor" }, nil, 7)
    eq(table.concat(m.grants(), ","), "firefox,*", "no grant for editor, so nothing changes")
    eq(pcall(m.extend, "*", { "a" }, nil, 7), false, "a wildcard grant can't be widened")
    eq(pcall(m.extend, "editor", "a", nil, 7), false, "ids must be a list")
    eq(pcall(m.extend, "editor", { "a", "*" }, nil, 7), false, "* isn't an id to add")
    eq(pcall(m.extend, "editor", { "" }, nil, 7), false, "an empty id")
    eq(pcall(m.extend, "editor", { "a" }), false, "the grant's key is required")
    eq(pcall(m.grant, "editor", nil, "7"), false, "a key is an integer")
end)

test("extend widens only the grant its lookup was for", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("libreoffice", nil, 7) -- libreoffice --writer, still reading entries
    fire("input.keyboard.key", 36, 5001, 1) -- canceled by the key launching Calc
    m.grant("libreoffice", nil, 8) -- libreoffice --calc
    m.extend("libreoffice", { "libreoffice-writer" }, nil, 7) -- Writer's lookup, late
    m.extend("libreoffice", { "libreoffice-calc" }, nil, 8)
    eq(table.concat(m.grants(), ","), "libreoffice libreoffice-calc", "Calc's grant holds Calc's class only")
end)

test("a key press cancels the grant; a release doesn't", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    fire("input.keyboard.key", 36, 5000, 0)
    eq(#m.grants(), 1, "release keeps it")
    fire("input.keyboard.key", 36, 5001, 1)
    eq(#m.grants(), 0, "press cancels it")
    local ff = window("firefox")
    eq(is_attention(fire("window.open", ff)[1], ff), true, "announced")
end)

test("moving focus cancels the grant, whatever moved it", function()
    for _, reason in ipairs({ FFM, KEYBIND, CLICK, WORKSPACE }) do
        local m = load()
        focused(window("kitty"), FFM)
        m.grant("firefox")
        focused(window("code"), reason)
        eq(#m.grants(), 0, "reason " .. reason)
    end
end)

test("closing a window moves on, whichever window focus passes to", function()
    for _, reason in ipairs({ UNMAP_TILING, UNMAP_FLOATING }) do
        local m = load()
        focused(window("kitty"), FFM)
        m.grant("firefox")
        focused(window("code"), reason)
        eq(#m.grants(), 0, "reason " .. reason)
    end
end)

test("focus coming back to the window you were in doesn't cancel", function()
    local m = load()
    local kitty = window("kitty")
    focused(kitty, FFM)
    m.grant("firefox")
    -- The launcher closing: Hyprland refocuses the last window.
    focused(kitty, FFM)
    eq(#m.grants(), 1, "grants")
end)

test("the launcher closing on an empty workspace doesn't cancel, so the launch takes focus", function()
    for _, reason in ipairs({ FFM, KEYBIND, CLICK, WORKSPACE }) do
        local m = load()
        focused(window("kitty"), FFM)
        -- Super+Home to an empty home: focus on nothing, which is moving on.
        S.workspace = 2
        focused(nil, WORKSPACE)
        m.grant("firefox")
        -- The launcher closes, and Hyprland refocuses nothing again.
        focused(nil, reason)
        eq(#m.grants(), 1, "reason " .. reason)
        local ff = window("firefox")
        eq(is_focus(fire("window.open", ff)[1], ff), true, "focused, reason " .. reason)
    end
end)

test("going from one empty workspace to another still cancels", function()
    local m = load()
    S.workspace = 2
    focused(nil, WORKSPACE)
    m.grant("firefox")
    -- A click or the wheel on the bar, which no key press cancels.
    S.workspace = 3
    focused(nil, CLICK)
    eq(#m.grants(), 0, "grants")
end)

test("on Hyprland 0.57, named workspaces without IDs are told apart", function()
    -- From 0.57 a named workspace has an address, its name, and no ID.
    local function on_named()
        hl.get_active_workspace = function() return { addressable_name = S.workspace, name = S.workspace } end
    end
    local m = load()
    on_named()
    S.workspace = "docs"
    focused(nil, WORKSPACE)
    m.grant("firefox")
    focused(nil, CLICK)
    eq(#m.grants(), 1, "the launcher closing on the same empty workspace keeps the grant")
    S.workspace = "PR-12"
    focused(nil, CLICK)
    eq(#m.grants(), 0, "another empty workspace cancels it")
end)

test("leaving a window for an empty workspace still cancels", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    focused(nil, WORKSPACE)
    eq(#m.grants(), 0, "grants")
end)

test("the guard's own focusing doesn't cancel other grants", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    m.grant("chromium")
    -- Hyprland fires window.active synchronously from the focus dispatch.
    hl.dispatch = function(d)
        table.insert(S.dispatched, d)
        if d.dsp == "focus" then
            S.handlers["window.active"](nil, DISPATCH)
        end
    end
    fire("window.open", window("firefox"))
    eq(#m.grants(), 1, "chromium's grant survives")
end)

test("a grant on a named workspace takes its window there, made if new, focused", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox", nil, 7, { workspace = "PR-12, login" })
    local firefox = window("firefox")
    local d = fire("window.open", firefox)
    eq(#d, 2, "dispatches")
    eq(is_focus(d[1], firefox), true, "focused first")
    eq(d[2].dsp, "move", "then moved")
    eq(d[2].args.workspace, "name:PR-12, login", "to the workspace of that name")
    eq(d[2].args.follow, true, "and focus follows")
end)

test("with conf's move, a named workspace's window goes to its part on its own monitor", function()
    local m = load()
    local moved = {}
    _G.conf_workspaces = { move = function(...) table.insert(moved, { ... }) end }
    focused(window("kitty"), FFM)
    m.grant("firefox", nil, nil, { workspace = "docs" })
    local firefox = window("firefox")
    local d = fire("window.open", firefox)
    _G.conf_workspaces = nil
    eq(#d, 0, "no dispatch of the guard's own")
    eq(#moved, 1, "conf moves it")
    eq(moved[1][1], firefox.address, "that window")
    eq(moved[1][2], "docs", "to the workspace named")
    eq(moved[1][3], true, "and follows it")
    eq(moved[1][4], false, "saying nothing more of why, which the guard said")
    eq(#m.grants(), 0, "the grant is used up")
end)

test("a key press before a named workspace's window opens leaves it where you are", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox", nil, nil, { workspace = "docs" })
    fire("input.keyboard.key", nil, nil, 1)
    local firefox = window("firefox")
    local d = fire("window.open", firefox)
    eq(is_attention(d[1], firefox), true, "marked")
    for _, x in ipairs(d) do
        eq(x.dsp ~= "move" and not is_focus(x, firefox), true, "neither moved nor focused")
    end
end)

test("a grant on a named workspace focuses an existing window where it is", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("*", nil, nil, { workspace = "docs" })
    local chrome = window("google-chrome")
    local d = fire("window.urgent", chrome)
    eq(#d, 1, "dispatches")
    eq(is_focus(d[1], chrome), true, "focused, not moved")
end)

test("a plain grant leaves its window where it opened", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox", nil, nil, {})
    local firefox = window("firefox")
    local d = fire("window.open", firefox)
    eq(#d, 1, "dispatches")
    eq(is_focus(d[1], firefox), true, "focused")
end)

test("moving to the named workspace doesn't cancel other grants", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox", nil, nil, { workspace = "docs" })
    m.grant("chromium")
    -- Hyprland fires window.active from each dispatch: the focus, then the
    -- workspace change the move follows.
    local firefox = window("firefox")
    hl.dispatch = function(d)
        table.insert(S.dispatched, d)
        S.handlers["window.active"](firefox, d.dsp == "move" and WORKSPACE or DISPATCH)
    end
    fire("window.open", firefox)
    eq(#m.grants(), 1, "chromium's grant survives")
end)

test("grant rejects options it doesn't know", function()
    local m = load()
    eq(pcall(m.grant, "firefox", nil, nil, "new"), false, "not a table")
    eq(pcall(m.grant, "firefox", nil, nil, { place = "docs" }), false, "unknown option")
    eq(pcall(m.grant, "firefox", nil, nil, { new_workspace = true }), false, "gone: the name prompt names one")
    eq(pcall(m.grant, "firefox", nil, nil, { workspace = 3 }), false, "a workspace's name is text")
    eq(pcall(m.grant, "firefox", nil, nil, { workspace = "  " }), false, "with something in it")
    eq(pcall(m.grant, "firefox", nil, nil, { workspace = "a\nb" }), false, "on one line")
    eq(#m.grants(), 0, "no grant")
end)

test("focusing a window no grant asked for cancels the grants", function()
    for _, class in ipairs({ "kitty", "xdg-desktop-portal-gtk", "hyprpolkitagent" }) do
        local m = load()
        focused(window("kitty", 50), FFM)
        fire("input.keyboard.key", 28, 5000, 1) -- lets the polkit prompt in
        m.grant("firefox") -- a slow app launched after that key press
        local w = window(class)
        eq(is_focus(fire("window.open", w)[1], w), true, class .. " focused")
        eq(#m.grants(), 0, class .. " cancels firefox's grant")
    end
end)

test("focus on nothing forgets the app you were in", function()
    load()
    focused(window("kitty", 80), FFM)
    focused(nil, WORKSPACE)
    local later = window("kitty", 81)
    eq(is_attention(fire("window.open", later)[1], later), true, "announced")
end)

test("a focus dispatch that throws still clears the guard's own-focus flag", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    m.grant("chromium")
    hl.dsp.focus = function() error("window gone") end
    eq(pcall(fire, "window.open", window("firefox")), false, "the error propagates")
    -- A later focus change is the user moving on, so it cancels grants.
    focused(window("code"), FFM)
    eq(#m.grants(), 0, "grants canceled")
end)

test("a window with no address is neither focused nor announced", function()
    local m = load()
    focused(window("kitty"), FFM)
    local gone = window("kitty")
    gone.address = nil
    eq(#fire("window.open", gone), 0, "same app, gone")
    m.grant("firefox")
    local gone2 = window("firefox")
    gone2.address = nil
    eq(#fire("window.open", gone2), 0, "granted, gone")
    eq(#fire("window.open", (function() local w = window("other"); w.address = nil; return w end)()), 0, "other, gone")
end)

test("a launched app activating a window it already had takes focus", function()
    local m = load()
    focused(window("kitty"), FFM)
    local nautilus = window("org.gnome.Nautilus")
    m.grant("nautilus")
    eq(is_focus(fire("window.urgent", nautilus)[1], nautilus), true, "focused")
end)

test("any other activation stays marked (Hyprland marks it urgent)", function()
    load()
    focused(window("kitty"), FFM)
    local chrome = window("chromium")
    local d = fire("window.urgent", chrome)
    eq(#d, 1, "no focus")
    eq(is_attention(d[1], chrome), true, "announced to the shell")
end)

test("grant rejects an empty id", function()
    local m = load()
    eq(pcall(m.grant, ""), false, "empty")
    eq(pcall(m.grant, nil), false, "nil")
    eq(pcall(m.grant, "", 150), false, "empty, with a pid")
end)

test("with nothing focused yet, only granted windows take focus", function()
    local m = load()
    local first = window("kitty")
    eq(is_attention(fire("window.open", first)[1], first), true, "announced")
    m.grant("kitty")
    local second = window("kitty")
    eq(is_focus(fire("window.open", second)[1], second), true, "focused")
end)

test("the window focused at load counts as the app you're in", function()
    S = nil
    local kitty = window("kitty", 70)
    _G.hl = nil
    load() -- sets up the stub, then:
    S.active = kitty
    local m = dofile(dir .. "focus.lua")
    m.clock = function() return now end
    m.log = function(line) table.insert(S.logged, line) end
    m.setup({})
    local dialog = window("kitty", 70)
    eq(is_focus(fire("window.open", dialog)[1], dialog), true, "focused")
end)

-- The windows the guard holds as waiting, oldest first, as it announces
-- them again for a shell that restarted.
local function waiting(m)
    S.dispatched = {}
    m.announce_waiting()
    local out = {}
    for _, d in ipairs(S.dispatched) do
        if d.dsp == "event" and d.args:find("^tide%-attention>>") then
            table.insert(out, (d.args:gsub("^tide%-attention>>", "")))
        end
    end
    return table.concat(out, " ")
end

test("the attention cycle is gone: the shell's Attention tab lists the marks", function()
    local m = load()
    eq(m.focus_attention, nil, "no focus_attention")
    eq(m.end_cycle, nil, "no end_cycle")
    focused(window("kitty"), FFM)
    local a, b = window("updater"), window("chat")
    fire("window.open", a)
    fire("window.open", b)
    eq(waiting(m), a.address .. " " .. b.address, "both wait, oldest first")
    for _, d in ipairs(S.dispatched) do
        eq(tostring(d.args):find("tide%-cycle") == nil, true, "and no cycle events")
    end
end)

test("set_order takes the shell's list of addresses, and only that", function()
    local m = load()
    m.set_order({ "0x1", "2" })
    eq(pcall(m.set_order, "0x1"), false, "rejects a string")
    eq(pcall(m.set_order, { 1 }), false, "rejects a number")
end)

test("an activation without a grant waits with the rest, and the shell hears it", function()
    local m = load()
    focused(window("kitty"), FFM)
    local popup, chat = window("updater"), window("chromium")
    fire("window.open", popup)
    local d = fire("window.urgent", chat)
    eq(is_attention(d[1], chat), true, "announced, so the bar keeps it past Hyprland's flag")
    eq(#S.notified, 1, "without a notification of its own")
    eq(waiting(m), popup.address .. " " .. chat.address, "the activation is the latest")
end)

test("a waiting window you reach another way, or that closes, stops waiting", function()
    local m = load()
    focused(window("kitty"), FFM)
    local a, b = window("updater"), window("chat")
    fire("window.open", a)
    fire("window.open", b)
    focused(b, CLICK)
    fire("window.close", a)
    eq(waiting(m), "", "nothing waiting")
end)

test("a waiting window shows a notification unless notify is off", function()
    load()
    focused(window("kitty"), FFM)
    fire("window.open", window("updater"))
    eq(#S.notified, 1, "notified")
    eq(S.notified[1].text:find("updater", 1, true) ~= nil, true, "names the app")
    eq(S.notified[1].text:find("Super+A", 1, true) ~= nil, true, "names the key")
    load({ notify = false })
    focused(window("kitty"), FFM)
    fire("window.open", window("updater"))
    eq(#S.notified, 0, "silent")
end)

test("once a shell marks waiting windows, the guard's notification stops", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.set_order({}) -- the shell, starting with nothing marked
    local updater = window("updater")
    local d = fire("window.open", updater)
    eq(#S.notified, 0, "the bar marks it instead")
    eq(is_attention(d[1], updater), true, "still announced")
end)

test("the waiting windows can be announced again, for a shell that restarted", function()
    local m = load()
    focused(window("kitty"), FFM)
    local a, b = window("updater"), window("chat")
    fire("window.open", a)
    fire("window.open", b)
    S.dispatched, S.notified = {}, {}
    m.announce_waiting()
    eq(#S.dispatched, 2, "both")
    eq(is_attention(S.dispatched[1], a), true, "oldest first")
    eq(is_attention(S.dispatched[2], b), true, "then the newer")
    eq(#S.notified, 0, "no second notification")
    focused(a, CLICK)
    S.dispatched = {}
    m.announce_waiting()
    eq(#S.dispatched, 1, "only what still waits")
    eq(is_attention(S.dispatched[1], b), true, "the one left")
end)

-- A clicked notification's grant (SPEC.md §9).
local function history(w, id)
    w.focus_history_id = id
    return w
end

test("a notification's unused grant focuses the app's most recent window", function()
    local m = load()
    local older = history(window("org.example.Chat"), 3)
    local recent = history(window("org.example.Chat"), 1)
    local other = history(window("kitty"), 0)
    S.windows = { older, recent, other }
    m.grant_or_recent("org.example.Chat")
    eq(#S.timers, 1, "timers")
    eq(S.timers[1].opts.timeout, 10000, "runs as long as a grant")
    eq(S.timers[1].opts.type, "oneshot", "once")
    S.dispatched = {}
    S.timers[1].fn()
    eq(#S.dispatched, 1, "one dispatch")
    eq(is_focus(S.dispatched[1], recent), true, "the window focused last")
    eq(#m.grants(), 0, "the grant is gone")
end)

test("a notification's grant used by the app's activation doesn't fall back", function()
    local m = load()
    local chat = history(window("org.example.Chat"), 2)
    local other = history(window("org.example.Chat"), 1)
    S.windows = { chat, other }
    m.grant_or_recent("org.example.Chat")
    eq(is_focus(fire("window.urgent", chat)[1], chat), true, "the activation takes focus")
    S.dispatched = {}
    S.timers[1].fn()
    eq(#S.dispatched, 0, "nothing more")
end)

test("a notification's grant used by a new window doesn't fall back", function()
    local m = load()
    S.windows = { history(window("org.example.Chat"), 0) }
    m.grant_or_recent("org.example.Chat")
    local new = window("org.example.Chat")
    eq(is_focus(fire("window.open", new)[1], new), true, "the new window takes focus")
    S.dispatched = {}
    S.timers[1].fn()
    eq(#S.dispatched, 0, "nothing more")
end)

test("moving on cancels the fallback too", function()
    local m = load()
    S.windows = { history(window("org.example.Chat"), 1) }
    m.grant_or_recent("org.example.Chat")
    fire("input.keyboard.key", nil, nil, 1)
    S.dispatched = {}
    S.timers[1].fn()
    eq(#S.dispatched, 0, "a key press")

    m = load()
    S.windows = { history(window("org.example.Chat"), 1) }
    m.grant_or_recent("org.example.Chat")
    focused(window("kitty"), FFM)
    S.dispatched = {}
    S.timers[1].fn()
    eq(#S.dispatched, 0, "the pointer moving into another window")
end)

test("with no window ever focused, any of the app's windows comes up", function()
    local m = load()
    local w = history(window("org.example.Chat"), -1)
    S.windows = { history(window("kitty"), 0), w }
    m.grant_or_recent("chat") -- a bare name matches a qualified class
    S.dispatched = {}
    S.timers[1].fn()
    eq(is_focus(S.dispatched[1], w), true, "its never-focused window")
end)

test("an app with no window gets nothing when its grant runs out", function()
    local m = load()
    S.windows = { history(window("kitty"), 0) }
    m.grant_or_recent("org.example.Chat")
    S.dispatched = {}
    S.timers[1].fn()
    eq(#S.dispatched, 0, "no dispatch")
    eq(#m.grants(), 0, "and no grant left")
end)

test("a window list that can't be read is an error, not a silent nothing", function()
    local m = load()
    hl.get_windows = function() error("no compositor") end
    m.grant_or_recent("org.example.Chat")
    S.dispatched = {}
    local ok, err = pcall(S.timers[1].fn)
    eq(ok, false, "the timer callback fails, so Hyprland logs it")
    eq(tostring(err):find("couldn't list windows to bring up org.example.chat: ", 1, true) ~= nil, true, err)
    eq(tostring(err):find("no compositor", 1, true) ~= nil, true, "names the cause")
    eq(#S.dispatched, 0, "no dispatch")
end)

test("a notification's grant still falls back when the timer runs late", function()
    local m = load()
    local w = history(window("org.example.Chat"), 0)
    S.windows = { w }
    m.grant_or_recent("org.example.Chat")
    now = now + 30 -- the timer fires late, after another grant expired this one
    m.grant("kitty")
    eq(#m.grants(), 1, "only kitty's grant is left")
    S.dispatched = {}
    S.timers[1].fn()
    eq(is_focus(S.dispatched[1], w), true, "running out is what brings the window up")
end)

test("a notification's grant needs an app", function()
    local m = load()
    eq(pcall(m.grant_or_recent, "*"), false, "wildcard")
    eq(pcall(m.grant_or_recent, nil), false, "nil")
    eq(pcall(m.grant_or_recent, ""), false, "empty")
    eq(#S.timers, 0, "no timer")
end)

test("focus_recent brings up the app's most recent window at once", function()
    local m = load()
    local older = history(window("org.example.Chat"), 2)
    local recent = history(window("org.example.Chat"), 1)
    S.windows = { older, recent, history(window("kitty"), 0) }
    m.grant("firefox")
    S.dispatched = {}
    m.focus_recent("chat")
    eq(#S.dispatched, 1, "one dispatch")
    eq(is_focus(S.dispatched[1], recent), true, "the window focused last")
    eq(#S.timers, 0, "no waiting")
    eq(#m.grants(), 0, "choosing a window cancels pending grants")
end)

test("focus_recent with no window does nothing, and says so", function()
    local m = load()
    S.windows = { history(window("kitty"), 0) }
    local printed = {}
    local real = print
    print = function(...) table.insert(printed, table.concat({ ... }, " ")) end
    S.dispatched = {}
    local ok, err = pcall(m.focus_recent, "org.example.Chat")
    print = real
    eq(ok, true, tostring(err))
    eq(#S.dispatched, 0, "no dispatch")
    eq(printed[1], "tide focus: no window of org.example.chat to bring up", "logged")
    eq(pcall(m.focus_recent, "*"), false, "wildcard")
    eq(pcall(m.focus_recent, nil), false, "nil")
end)

test("a notification's grant can name several apps, and covers each", function()
    -- A Chrome site open as an --app window in two profiles is two classes.
    local m = load()
    local work = history(window("chrome-calendar.google.com__-Profile_1"), 2)
    local home = history(window("chrome-calendar.google.com__-Default"), 1)
    S.windows = { work, home, history(window("kitty"), 0) }
    m.grant_or_recent({ "chrome-calendar.google.com__-Default", "chrome-calendar.google.com__-Profile_1" })
    eq(m.grants()[1], "chrome-calendar.google.com__-default chrome-calendar.google.com__-profile_1", "both")
    eq(is_focus(fire("window.urgent", work)[1], work), true, "either one's activation takes focus")

    m = load()
    S.windows = { work, home }
    m.grant_or_recent({ "chrome-calendar.google.com__-Default", "chrome-calendar.google.com__-Profile_1" })
    S.dispatched = {}
    S.timers[1].fn()
    eq(is_focus(S.dispatched[1], home), true, "running out brings up the one focused last")
    eq(pcall(m.grant_or_recent, {}), false, "an empty list")
    eq(pcall(m.grant_or_recent, { "kitty", "*" }), false, "a wildcard in the list")
end)

test("focus_recent takes several apps", function()
    local m = load()
    local work = history(window("chrome-calendar.google.com__-Profile_1"), 1)
    local home = history(window("chrome-calendar.google.com__-Default"), 3)
    S.windows = { work, home }
    S.dispatched = {}
    m.focus_recent({ "chrome-calendar.google.com__-Default", "chrome-calendar.google.com__-Profile_1" })
    eq(is_focus(S.dispatched[1], work), true, "the one focused last")
end)

-- A minimized window (SPEC.md §6.7) sits on special:minimized:NAME.
local function minimized(w, from)
    w.workspace = { id = -97, name = "special:minimized:" .. from }
    return w
end

-- The restore: focus the window, then move it back to `from`, following it.
local function restored(d, w, from)
    eq(#d, 2, "dispatches")
    eq(is_focus(d[1], w), true, "focused first")
    eq(d[2].dsp, "move", "then moved")
    eq(d[2].args.workspace, "name:" .. from, "back to the workspace it came from")
    eq(d[2].args.follow, true, "and focus follows")
end

test("a past notification's click restores a minimized window rather than showing the minimize workspace", function()
    local m = load()
    local chat = minimized(history(window("org.example.Chat"), 1), "re")
    S.windows = { chat, history(window("kitty"), 0) }
    S.dispatched = {}
    m.focus_recent("chat")
    restored(S.dispatched, chat, "re")
end)

test("a notification's grant running out restores a minimized window", function()
    local m = load()
    local chat = minimized(history(window("org.example.Chat"), 1), "PR-12, login")
    S.windows = { chat }
    m.grant_or_recent("org.example.Chat")
    S.dispatched = {}
    S.timers[1].fn()
    restored(S.dispatched, chat, "PR-12, login")
end)

test("an app's activation with a grant restores its minimized window", function()
    local m = load()
    local chat = minimized(history(window("org.example.Chat"), 1), "re")
    S.windows = { chat }
    m.grant_or_recent("org.example.Chat")
    restored(fire("window.urgent", chat), chat, "re")
end)

test("a window on another special workspace is only focused", function()
    local m = load()
    local w = history(window("org.example.Chat"), 1)
    w.workspace = { id = -98, name = "special:scratch" }
    S.windows = { w }
    S.dispatched = {}
    m.focus_recent("chat")
    eq(#S.dispatched, 1, "one dispatch")
    eq(is_focus(S.dispatched[1], w), true, "focused where it is")
end)

test("grant_seconds sets how long a notification's grant waits", function()
    local m = load({ grant_seconds = 4 })
    m.grant_or_recent("kitty")
    eq(S.timers[1].opts.timeout, 4000, "timeout")
end)

-- next_attention (SPEC.md §14.3), the unbound next_attention key's without
-- the shell: the window it went to, or nil, and whether it went.
local function next_attention(m)
    S.dispatched = {}
    local went = m.next_attention()
    for _, d in ipairs(S.dispatched) do
        if d.dsp == "focus" then
            return went, (d.args.window:gsub("^address:", ""))
        end
    end
    return went, nil
end

test("next_attention goes to the latest waiting window, then the next, then nowhere", function()
    local m = load()
    focused(window("kitty"), FFM)
    local a, b = window("one"), window("two")
    fire("window.open", a)
    fire("window.open", b)
    S.windows = { a, b }
    local went, to = next_attention(m)
    eq(went, true, "went")
    eq(to, b.address, "the latest first")
    -- Going there clears its mark, before Hyprland says it's focused.
    went, to = next_attention(m)
    eq(to, a.address, "then the older one")
    focused(a, DISPATCH)
    went, to = next_attention(m)
    eq(went, false, "none left")
    eq(to, nil, "and nothing focused, not the last window")
    eq(#S.dispatched, 0, "no dispatch at all")
end)

test("next_attention follows the shell's order, newest first", function()
    local m = load()
    focused(window("kitty"), FFM)
    local waiting, chat = window("updater"), window("chat")
    fire("window.open", waiting)
    S.windows = { waiting, chat }
    -- The shell sees the guard's window and a notification's, oldest
    -- first; it may write an address without the 0x.
    m.set_order({ waiting.address, (chat.address:gsub("^0x", "")) })
    local _, to = next_attention(m)
    eq(to, chat.address, "the shell's newest")
    _, to = next_attention(m)
    eq(to, waiting.address, "then the older one")
    eq(next_attention(m), false, "the shell's list is used up")
end)

test("next_attention takes a window announced since the shell last spoke as the newest", function()
    local m = load()
    focused(window("kitty"), FFM)
    local chat, late = window("chat"), window("late")
    S.windows = { chat, late }
    m.set_order({ chat.address })
    fire("window.open", late)
    local _, to = next_attention(m)
    eq(to, late.address, "the one the shell hasn't listed yet")
    _, to = next_attention(m)
    eq(to, chat.address, "then the shell's")
end)

test("next_attention takes a listed window that asks again as the newest", function()
    local m = load()
    focused(window("kitty"), FFM)
    local a, b = window("one"), window("two")
    S.windows = { a, b }
    m.set_order({ a.address, b.address })
    fire("window.urgent", a)
    local _, to = next_attention(m)
    eq(to, a.address, "the one that asked again")
    _, to = next_attention(m)
    eq(to, b.address, "then the shell's next")
    eq(next_attention(m), false, "and each only once")
end)

test("next_attention keeps out a waiting window the shell's list left out", function()
    local m = load()
    focused(window("kitty"), FFM)
    local muted, chat = window("muted"), window("chat")
    fire("window.open", muted)
    S.windows = { muted, chat }
    -- The shell leaves out a muted app's window, and stops later.
    m.set_order({ chat.address })
    local _, to = next_attention(m)
    eq(to, chat.address, "the shell's")
    eq(next_attention(m), false, "not the window it left out")
    m.set_order({})
    eq(next_attention(m), false, "nor after an empty list")
end)

test("focusing a marked window another way takes it off the shell's list", function()
    local m = load()
    focused(window("kitty"), FFM)
    local chat, mail = window("chat"), window("mail")
    S.windows = { chat, mail }
    m.set_order({ chat.address, mail.address })
    focused(mail, CLICK)
    local _, to = next_attention(m)
    eq(to, chat.address, "mail was attended to")
end)

test("next_attention restores a minimized window to the workspace it came from", function()
    local m = load()
    focused(window("kitty"), FFM)
    local chat = minimized(window("org.example.Chat"), "re")
    S.windows = { chat }
    m.set_order({ chat.address })
    S.dispatched = {}
    eq(m.next_attention(), true, "went")
    restored(S.dispatched, chat, "re")
end)

test("next_attention cancels the grants: you chose another window", function()
    local m = load()
    focused(window("kitty"), FFM)
    local w = window("updater")
    fire("window.open", w)
    S.windows = { w }
    m.grant("firefox")
    eq(m.next_attention(), true, "went")
    eq(#m.grants(), 0, "canceled")
end)

-- minimize (SPEC.md §6.7): the shell minimizes a window through the
-- guard, which then focuses the window under the pointer, or the one you
-- were in before. Windows are laid out as Hyprland has them once the
-- minimized one has gone: its spot taken by the window that re-tiled there.
local SHOWN = { id = 1, name = "1", visible = true }
local HIDDEN = { id = 2, name = "2", visible = false }

local function placed(w, x, y, wd, ht, ws, history)
    w.at, w.size, w.workspace, w.focus_history_id = { x = x, y = y }, { x = wd, y = ht }, ws or SHOWN, history or -1
    return w
end

-- Minimizes `gone` with the pointer at x, y: the dispatches the guard made.
local function minimize(m, gone, x, y)
    hl.get_cursor_pos = function() return { x = x, y = y } end
    S.active = gone
    minimized(gone, "1")
    S.dispatched = {}
    m.minimize(gone.address, "1")
    return S.dispatched
end

local function is_minimize(d, w)
    return d and d.dsp == "move" and d.args.window == "address:" .. w.address
        and d.args.workspace == "special:minimized:1" and d.args.follow == false
end

test("minimize moves the window to its workspace's minimize workspace, silently", function()
    local m = load()
    local gone = placed(window("kitty"), 0, 0, 500, 1000)
    S.windows = { gone }
    local d = minimize(m, gone, 250, 500)
    eq(is_minimize(d[1], gone), true, "moved")
    eq(#d, 1, "and nothing to focus")
end)

test("minimize focuses the window that re-tiled under the pointer", function()
    local m = load()
    local gone, left, right = window("kitty"), window("chat"), window("mail")
    placed(left, 0, 0, 1000, 500, SHOWN, 1)
    placed(right, 0, 500, 1000, 500, SHOWN, 2) -- now where the pointer is
    S.windows = { gone, left, right }
    local d = minimize(m, gone, 900, 900)
    eq(is_minimize(d[1], gone), true, "moved")
    eq(is_focus(d[2], right), true, "under the pointer, not the one used last")
end)

test("minimize prefers a floating window over the tile under it", function()
    local m = load()
    local gone, tile, float = window("kitty"), window("chat"), window("calc")
    placed(tile, 0, 0, 1000, 1000, SHOWN, 1)
    placed(float, 400, 400, 200, 200, SHOWN, 2).floating = true
    S.windows = { gone, tile, float }
    eq(is_focus(minimize(m, gone, 500, 500)[2], float), true, "the floating one, on top")
end)

test("minimize with the pointer over no window focuses the window you were in before", function()
    local m = load()
    local gone, older, last = window("kitty"), window("chat"), window("mail")
    placed(older, 0, 0, 500, 500, SHOWN, 2)
    placed(last, 500, 0, 500, 500, SHOWN, 1)
    local music = placed(window("music"), 0, 0, 1000, 1000, HIDDEN, 0) -- under it, but not shown
    S.windows = { gone, older, last, music }
    local d = minimize(m, gone, 500, 800) -- below both: the bar, or a gap
    eq(is_focus(d[2], last), true, "the one used last that's shown")
end)

test("minimize doesn't focus a waiting window under the pointer", function()
    local m = load()
    focused(window("kitty"), FFM)
    local gone, waiting, last = window("kitty"), window("updater"), window("mail")
    fire("window.open", waiting)
    placed(waiting, 0, 0, 1000, 500, SHOWN, -1)
    placed(last, 0, 500, 1000, 500, SHOWN, 1)
    S.windows = { gone, waiting, last }
    eq(is_focus(minimize(m, gone, 500, 200)[2], last), true, "the one you were in before")
end)

test("minimizing a window you aren't in moves no focus", function()
    local m = load()
    local gone, here = placed(window("kitty"), 0, 0, 500, 500), placed(window("chat"), 500, 0, 500, 500, SHOWN, 0)
    S.windows = { gone, here }
    hl.get_cursor_pos = function() return { x = 100, y = 100 } end
    S.active = here
    S.dispatched = {}
    m.minimize(gone.address, "1")
    eq(#S.dispatched, 1, "only the move")
end)

test("minimize doesn't focus a window under the pointer on another monitor", function()
    local m = load()
    local gone, here, there = window("kitty"), window("chat"), window("mail")
    gone.monitor, here.monitor, there.monitor = { id = 0 }, { id = 0 }, { id = 1 }
    placed(gone, 0, 0, 1000, 1000)
    placed(here, 0, 0, 1000, 1000, SHOWN, 1)
    placed(there, 1000, 0, 1000, 1000, { id = 3, name = "3", visible = true }, 2)
    S.windows = { gone, here, there }
    eq(is_focus(minimize(m, gone, 1500, 500)[2], here), true, "the one you were in before, on its monitor")
end)

test("minimize falls back to the window used before it, not the one Hyprland focused moving it", function()
    local m = load()
    local gone, mid, last = window("kitty"), window("chat"), window("mail")
    placed(gone, 0, 0, 500, 500, SHOWN, 0)
    placed(mid, 500, 0, 500, 500, SHOWN, 2)
    placed(last, 0, 500, 500, 500, SHOWN, 1)
    S.windows = { gone, mid, last }
    -- Hyprland's silent move focuses the window at the old one's middle,
    -- which then heads the focus history.
    local dispatch = hl.dispatch
    hl.dispatch = function(d)
        dispatch(d)
        if d.dsp == "move" then
            mid.focus_history_id, last.focus_history_id, gone.focus_history_id = 0, 2, 1
        end
    end
    eq(is_focus(minimize(m, gone, 500, 2000)[2], last), true, "the one you were in before minimizing")
end)

test("minimize's fallback skips a window the guard keeps waiting", function()
    local m = load()
    focused(window("kitty"), FFM)
    local gone, asking, older = window("kitty"), window("chat"), window("mail")
    placed(asking, 500, 0, 500, 500, SHOWN, 1)
    placed(older, 0, 500, 500, 500, SHOWN, 2)
    S.windows = { gone, asking, older }
    fire("window.urgent", asking) -- used before, now asking without a grant
    eq(is_focus(minimize(m, gone, 500, 2000)[2], older), true, "not the waiting one")
end)

test("minimize doesn't focus a floating window where it overhangs another monitor", function()
    local m = load()
    local gone, float, last = window("kitty"), window("calc"), window("mail")
    gone.monitor, float.monitor, last.monitor = { id = 0 }, { id = 0 }, { id = 0 }
    placed(gone, 0, 0, 1000, 1000, SHOWN, 0)
    placed(float, 900, 100, 300, 300, SHOWN, 2).floating = true -- into monitor 1, from x 1000
    placed(last, 0, 0, 1000, 1000, SHOWN, 1)
    S.windows = { gone, float, last }
    hl.get_monitor_at_cursor = function() return { id = 1 } end
    eq(is_focus(minimize(m, gone, 1100, 200)[2], last), true, "the pointer is on monitor 1")
end)

test("minimize rejects a bad address or workspace name", function()
    local m = load()
    eq(pcall(m.minimize, "x) os.exit(", "1"), false, "address")
    eq(pcall(m.minimize, "0x1", ""), false, "empty name")
    eq(pcall(m.minimize, "0x1", 5), false, "not a name")
end)

-- Why focus moved (SPEC.md §5.4, Reporting a bug): a `tide why:` line
-- for each of the guard's choices, and for each focus change it didn't
-- make, with Hyprland's reason.
local function logged(text)
    for _, line in ipairs(S.logged) do
        if line == text then
            return true
        end
    end
    return false
end

test("a launched app's window says it took focus because you launched it", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    local firefox = window("firefox")
    fire("window.open", firefox)
    eq(logged("tide why: focus firefox (" .. firefox.address .. "): you launched its app just now"), true, "logged")
end)

test("a launch on a named workspace says it moved the window there, and why", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox", nil, nil, { workspace = "docs" })
    local firefox = window("firefox")
    fire("window.open", firefox)
    eq(logged("tide why: focus firefox (" .. firefox.address .. "), moving it to workspace docs: its launch asked for that workspace"), true, "logged")
end)

test("a window nothing asked for says it was left unfocused, and why", function()
    load()
    focused(window("kitty"), FFM)
    local popup = window("updater")
    fire("window.open", popup)
    eq(logged("tide why: leave updater (" .. popup.address .. ") unfocused, marked for attention: nothing asked for it"), true, "logged")
end)

test("an activation without a grant says it was kept from focus", function()
    load()
    focused(window("kitty"), FFM)
    local mail = window("mail")
    fire("window.urgent", mail)
    eq(logged("tide why: leave mail (" .. mail.address .. ") unfocused, marked for attention: it asked for focus with no launch grant"), true, "logged")
end)

test("a new window of the app you're in says so", function()
    load()
    focused(window("kitty", 50), FFM)
    local second = window("kitty", 50)
    fire("window.open", second)
    eq(logged("tide why: focus kitty (" .. second.address .. "): a new window of the app you're in"), true, "logged")
end)

test("focus the guard didn't move is logged with Hyprland's reason", function()
    load()
    local kitty = window("kitty")
    focused(kitty, FFM)
    eq(logged("tide why: kitty (" .. kitty.address .. ") has focus on workspace 1: the pointer"), true, "the pointer")
    local mail = window("mail")
    S.workspace = 2
    focused(mail, WORKSPACE)
    eq(logged("tide why: mail (" .. mail.address .. ") has focus on workspace 2: a workspace change"), true, "a workspace change")
    focused(nil, KEYBIND)
    eq(logged("tide why: no window has focus on workspace 2: a key binding"), true, "nothing focused")
    focused(window("x"), 42)
    eq(S.logged[#S.logged]:match(": Hyprland's focus reason 42$") ~= nil, true, "an unknown reason by number")
end)

test("the guard's own focusing isn't logged twice", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    local firefox = window("firefox")
    -- Hyprland moves focus within the dispatch, so window.active comes
    -- while the guard is still focusing.
    local dispatch = hl.dispatch
    hl.dispatch = function(d)
        dispatch(d)
        if is_focus(d, firefox) then
            S.handlers["window.active"](firefox, DISPATCH)
        end
    end
    local before = #S.logged
    fire("window.open", firefox)
    eq(#S.logged, before + 1, "one line, the guard's, for the focus it made")
end)

test("a dropped grant says what dropped it", function()
    local m = load()
    focused(window("kitty"), FFM)
    m.grant("firefox")
    fire("input.keyboard.key", nil, nil, 1)
    eq(logged("tide why: drop the launch grant for firefox: a key press"), true, "a key press")
    m.grant("mail")
    focused(window("files"), CLICK)
    eq(logged("tide why: drop the launch grant for mail: focus moved, by a click"), true, "a click")
    local count = #S.logged
    fire("input.keyboard.key", nil, nil, 1)
    eq(#S.logged, count, "no line when there was no grant to drop")
end)

io.write(string.format("focus_test.lua: %d passed, %d failed\n", passed, failures))
os.exit(failures == 0 and 0 or 1)
