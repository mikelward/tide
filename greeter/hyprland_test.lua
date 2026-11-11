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
local function load(environ, refuse)
    S = { config = {}, monitors = {}, handlers = {}, exec = {}, other = {}, dispatched = {} }
    local hl = setmetatable({
        config = function(t)
            if refuse and t[refuse] then
                error("no config section " .. refuse)
            end
            for k, v in pairs(t) do
                S.config[k] = v
            end
        end,
        monitor = function(m)
            if refuse == "monitor" then
                error("no hl.monitor")
            end
            table.insert(S.monitors, m)
        end,
        on = function(ev, fn) S.handlers[ev] = fn end,
        exec_cmd = function(cmd) table.insert(S.exec, cmd) end,
        get_active_monitor = function() return S.active_monitor end,
        dispatch = function(d) table.insert(S.dispatched, d) end,
        dsp = { cursor = { move = function(at) return { cursor_move = at } end } },
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
-- the test, whatever it printed. With `qs_exit`, qs exits with that.
local function run(cmd, qs_exit, no_journal)
    local bin = os.tmpname()
    os.remove(bin)
    assert(os.execute("mkdir -p '" .. bin .. "'"))
    -- systemd-cat marks each line it would send to the journal, unless
    -- the test says there's none: PATH is only these stand-ins.
    if not no_journal then
        local f = assert(io.open(bin .. "/systemd-cat", "w"))
        f:write("#!/bin/sh\nwhile IFS= read -r line; do printf 'journal(%s) %s\\n' \"$1\" \"$line\"; done\n")
        f:close()
        assert(os.execute("chmod +x '" .. bin .. "/systemd-cat'"))
    end
    for _, name in ipairs({ "qs", "hyprctl" }) do
        local f = assert(io.open(bin .. "/" .. name, "w"))
        f:write("#!/bin/sh\nprintf '" .. name .. "'\nprintf ' [%s]' \"$@\"\nprintf ' watcher=%s\\n' \"${QS_DISABLE_FILE_WATCHER:-}\"\n")
        if name == "qs" and qs_exit then
            f:write("exit " .. qs_exit .. "\n")
        end
        f:close()
        assert(os.execute("chmod +x '" .. bin .. "/" .. name .. "'"))
    end
    -- From a file, as `sh -c` would run it, with no quoting of its own.
    local f = assert(io.open(bin .. "/cmd.sh", "w"))
    f:write(cmd .. "\n")
    f:close()
    local p = assert(io.popen("PATH='" .. bin .. "' /bin/sh '" .. bin .. "/cmd.sh' 2>&1"))
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

test("Hyprland's log goes to greetd's journal, without color codes", function()
    load({})
    eq(S.config.debug.enable_stdout_logs, true, "stdout logs")
    eq(S.config.debug.colored_stdout_logs, false, "colored")
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
    eq(out, "journal(--identifier=tide-greeter) tide-greeter: starting the greeter (qs)\n"
        .. "journal(--identifier=tide-greeter) qs [-p] [/usr/share/tide/shell/greeter.qml] watcher=1\n"
        .. "journal(--identifier=tide-greeter) tide-greeter: the greeter (qs) exited 0\n"
        .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran")
end)

test("at start the pointer goes to the middle of the focused monitor", function()
    load({ TIDE_GREETER_QML = "/q.qml" })
    S.active_monitor = { x = 1920, y = 0, mode = { width = 2560, height = 1440 } }
    start()
    eq(#S.dispatched, 1, "pointer moves")
    eq(S.dispatched[1].cursor_move.x, 3200, "x")
    eq(S.dispatched[1].cursor_move.y, 720, "y")
end)

test("with no monitor to read, the pointer stays put and the greeter still runs", function()
    load({ TIDE_GREETER_QML = "/q.qml" })
    start()
    eq(#S.dispatched, 0, "pointer moves")
end)

test("a path with quotes and spaces reaches qs whole", function()
    load({ TIDE_GREETER_QML = "/opt/it's a $HOME `x`/greeter.qml" })
    local out = run(start())
    eq(out, "journal(--identifier=tide-greeter) tide-greeter: starting the greeter (qs)\n"
        .. "journal(--identifier=tide-greeter) qs [-p] [/opt/it's a $HOME `x`/greeter.qml] watcher=1\n"
        .. "journal(--identifier=tide-greeter) tide-greeter: the greeter (qs) exited 0\n"
        .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran")
end)

test("with no greeter given, it says so and exits Hyprland", function()
    load({})
    local out = run(start())
    eq(out, "journal(--identifier=tide-greeter) tide-greeter: no TIDE_GREETER_QML, so no greeter to run\n"
        .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran")
end)

-- What `path` holds, or nil without it.
local function slurp(path)
    local f = io.open(path)
    if not f then
        return nil
    end
    local text = f:read("a")
    f:close()
    return text
end

test("the greeter's exit status is left where tide-greeter asked, then Hyprland exits", function()
    -- A directory, for a file name with a quote and a space in it.
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "'"))
    local status = dir .. "/it's a status"
    for _, code in ipairs({ 0, 3, 139 }) do
        load({ TIDE_GREETER_QML = "/usr/share/tide/shell/greeter.qml", TIDE_GREETER_QS_STATUS = status })
        local out = run(start(), code)
        eq(slurp(status), code .. "\n", "the status left for qs exiting " .. code)
        eq(out, "journal(--identifier=tide-greeter) tide-greeter: starting the greeter (qs)\n"
            .. "journal(--identifier=tide-greeter) qs [-p] [/usr/share/tide/shell/greeter.qml] watcher=1\n"
            .. "journal(--identifier=tide-greeter) tide-greeter: the greeter (qs) exited " .. code .. "\n"
            .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran when qs exited " .. code)
    end
    assert(os.execute("rm -rf '" .. dir .. "'"))
end)

test("a status that can't be written still exits Hyprland", function()
    load({ TIDE_GREETER_QML = "/usr/share/tide/shell/greeter.qml", TIDE_GREETER_QS_STATUS = "/nonexistent/dir/status" })
    local out = run(start(), 3)
    eq(out:find("hyprctl [dispatch] [hl.dsp.exit()]", 1, true) ~= nil, true, "Hyprland exits")
    eq(out:find("/nonexistent/dir/status", 1, true) ~= nil, true, "sh names the file it couldn't write")
end)

test("without systemd-cat, the greeter still runs and Hyprland exits", function()
    load({ TIDE_GREETER_QML = "/q.qml" })
    local out = run(start(), nil, true)
    eq(out, "tide-greeter: starting the greeter (qs)\n"
        .. "qs [-p] [/q.qml] watcher=1\n"
        .. "tide-greeter: the greeter (qs) exited 0\n"
        .. "hyprctl [dispatch] [hl.dsp.exit()] watcher=\n", "what ran")
end)

test("a setting this Hyprland refuses costs neither the greeter nor the other settings", function()
    for _, refuse in ipairs({ "misc", "input", "animations", "monitor" }) do
        load({ TIDE_GREETER_QML = "/usr/share/tide/shell/greeter.qml", TIDE_GREETER_KB_LAYOUT = "de" }, refuse)
        local out = run(start())
        eq(out:find("qs [-p] [/usr/share/tide/shell/greeter.qml]", 1, true) ~= nil, true, refuse .. ": the greeter runs")
        if refuse ~= "input" then
            eq(S.config.input.kb_layout, "de", refuse .. ": the keyboard")
        end
        if refuse ~= "misc" then
            eq(S.config.misc.key_press_enables_dpms, true, refuse .. ": the displays wake")
        end
    end
end)

io.write(string.format("hyprland_test.lua: %d passed, %d failed\n", passed, failures))
os.exit(failures == 0 and 0 or 1)
