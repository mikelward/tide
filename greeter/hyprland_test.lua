-- Tests for hyprland.lua, the greeter's compositor config (SPEC.md §11).
-- Plain Lua (5.4 or 5.5): `lua greeter/hyprland_test.lua` from the repo
-- root. The config runs against a stub of the Hyprland `hl` API that
-- records what it's given, with an environment the tests choose, as
-- tide-greeter would set it.

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

local S -- what the stub recorded

-- Loads the config with `environ` as its environment, and returns what it
-- set up. The start handler isn't run until the test runs it.
local function load(environ)
    S = { config = {}, monitors = {}, handlers = {}, exec = {}, other = {} }
    local hl = setmetatable({
        config = function(t)
            for k, v in pairs(t) do
                S.config[k] = v
            end
        end,
        monitor = function(m) table.insert(S.monitors, m) end,
        on = function(ev, fn) S.handlers[ev] = fn end,
        exec_cmd = function(cmd) table.insert(S.exec, cmd) end,
    }, {
        -- Anything else (a bind, a rule) is recorded, so a test can say
        -- there was none.
        __index = function(_, name)
            return function() table.insert(S.other, name) end
        end,
    })
    local fake_os = setmetatable({ getenv = function(name) return environ[name] end }, { __index = os })
    local env = setmetatable({ hl = hl, os = fake_os }, { __index = _G })
    local chunk = assert(loadfile(dir .. "hyprland.lua", "t", env))
    chunk()
    return S
end

local function start()
    assert(S.handlers["hyprland.start"], "no hyprland.start handler")()
    eq(#S.exec, 1, "commands run at start")
    return S.exec[1]
end

-- Runs `cmd` under sh with qs and hyprctl stubbed to print what they're
-- given, and returns what they printed. A command that exits nonzero fails
-- the test, whatever it printed.
local function run(cmd)
    local bin = os.tmpname()
    os.remove(bin)
    assert(os.execute("mkdir -p '" .. bin .. "'"))
    for _, name in ipairs({ "qs", "hyprctl" }) do
        local f = assert(io.open(bin .. "/" .. name, "w"))
        f:write("#!/bin/sh\nprintf '" .. name .. "'\nprintf ' [%s]' \"$@\"\nprintf ' watcher=%s\\n' \"${QS_DISABLE_FILE_WATCHER:-}\"\n")
        f:close()
        assert(os.execute("chmod +x '" .. bin .. "/" .. name .. "'"))
    end
    -- From a file, as `sh -c` would run it, with no quoting of its own.
    local f = assert(io.open(bin .. "/cmd.sh", "w"))
    f:write(cmd .. "\n")
    f:close()
    local p = assert(io.popen("PATH='" .. bin .. "':\"$PATH\" sh '" .. bin .. "/cmd.sh' 2>&1"))
    local out = p:read("a")
    local ok, how, code = p:close()
    assert(os.execute("rm -rf '" .. bin .. "'"))
    if not ok then
        error(string.format("the command %s %s; it printed: %s", how, tostring(code), out), 2)
    end
    return out
end

test("the keyboard is the one tide-greeter passes", function()
    load({
        TIDE_GREETER_KB_LAYOUT = "us",
        TIDE_GREETER_KB_MODEL = "pc105",
        TIDE_GREETER_KB_VARIANT = "dvorak",
        TIDE_GREETER_KB_OPTIONS = "compose:caps",
    })
    eq(S.config.input.kb_layout, "us", "kb_layout")
    eq(S.config.input.kb_model, "pc105", "kb_model")
    eq(S.config.input.kb_variant, "dvorak", "kb_variant")
    eq(S.config.input.kb_options, "compose:caps", "kb_options")
end)

test("with no keyboard given, Hyprland's defaults stand", function()
    load({ TIDE_GREETER_KB_VARIANT = "" })
    eq(S.config.input.kb_layout, "us", "kb_layout")
    eq(S.config.input.kb_model, "", "kb_model")
    eq(S.config.input.kb_variant, "", "kb_variant")
    eq(S.config.input.kb_options, "", "kb_options")
end)

test("every monitor gets its preferred mode, and Hyprland shows nothing of its own", function()
    load({})
    eq(#S.monitors, 1, "monitor rules")
    eq(S.monitors[1].output, "", "monitor output")
    eq(S.monitors[1].mode, "preferred", "monitor mode")
    eq(S.config.misc.disable_hyprland_logo, true, "logo")
    eq(S.config.misc.disable_splash_rendering, true, "splash")
    eq(S.config.misc.disable_watchdog_warning, true, "watchdog warning")
    eq(S.config.misc.disable_hyprland_guiutils_check, true, "guiutils warning")
    eq(S.config.ecosystem.no_update_news, true, "update news")
    eq(S.config.ecosystem.no_donation_nag, true, "donation nag")
end)

test("a key or a move turns the displays back on", function()
    load({})
    eq(S.config.misc.key_press_enables_dpms, true, "key_press_enables_dpms")
    eq(S.config.misc.mouse_move_enables_dpms, true, "mouse_move_enables_dpms")
    eq(S.config.animations.enabled, false, "animations")
end)

test("there are no key bindings, rules or anything else", function()
    load({ TIDE_GREETER_QML = "/usr/share/tide/shell/greeter.qml" })
    start()
    eq(#S.other, 0, "other hl calls (" .. table.concat(S.other, ", ") .. ")")
end)

test("nothing runs until Hyprland has started", function()
    load({ TIDE_GREETER_QML = "/usr/share/tide/shell/greeter.qml" })
    eq(#S.exec, 0, "commands run while loading")
end)

test("at start it runs the greeter, then exits Hyprland", function()
    load({ TIDE_GREETER_QML = "/usr/share/tide/shell/greeter.qml" })
    local out = run(start())
    eq(out, "qs [-p] [/usr/share/tide/shell/greeter.qml] watcher=1\n"
        .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran")
end)

test("a path with quotes and spaces reaches qs whole", function()
    load({ TIDE_GREETER_QML = "/opt/it's a $HOME `x`/greeter.qml" })
    local out = run(start())
    eq(out, "qs [-p] [/opt/it's a $HOME `x`/greeter.qml] watcher=1\n"
        .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran")
end)

test("with no greeter given, it says so and exits Hyprland", function()
    load({})
    local out = run(start())
    eq(out, "tide-greeter: no TIDE_GREETER_QML, so no greeter to run\n"
        .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran")
end)

io.write(string.format("hyprland_test.lua: %d passed, %d failed\n", passed, failures))
os.exit(failures == 0 and 0 or 1)
