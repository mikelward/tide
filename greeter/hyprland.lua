-- The tide greeter's compositor (tide SPEC.md §11): Hyprland with nothing
-- in it but the greeter. greetd runs `tide-greeter` as its greeter user,
-- which runs Hyprland with this file. Every monitor gets its preferred
-- mode, the keyboard is the system's, none of Hyprland's own popups show,
-- input turns the displays back on, and there are no key bindings:
-- Hyprland's built-in VT switch is the only key it acts on. It runs one
-- program, the greeter, and exits when the greeter does, which is once
-- greetd has the session to start; greetd then starts it. It exits 0
-- however the greeter ended, so the greeter's exit status is left in a
-- file for tide-greeter, which runs a text login after one that failed.
--
-- tide-greeter passes what this needs in the environment:
--   TIDE_GREETER_QML      the greeter's QML (share/tide/shell/greeter.qml)
--   TIDE_GREETER_KB_LAYOUT, TIDE_GREETER_KB_MODEL,
--   TIDE_GREETER_KB_VARIANT, TIDE_GREETER_KB_OPTIONS
--                         localed's X11 keymap; unset, Hyprland's defaults
--   TIDE_GREETER_QS_STATUS  the file to leave Quickshell's exit status in;
--                         unset, it's left nowhere

local function env(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

-- One word for sh, whatever it holds.
local function quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- How Hyprland exits from outside the config: hyprctl's dispatch, which a
-- Lua config takes as a Lua call (Hyprland 0.56).
local EXIT = "hyprctl dispatch 'hl.dsp.exit()'"

-- The greeter's command: Quickshell on the greeter's QML, then Hyprland's
-- exit, however Quickshell ends. In between, Quickshell's exit status goes
-- in `status_file`, where tide-greeter reads it: 0 is greetd having the
-- session to start, and after anything else tide-greeter runs a text
-- login. A status that can't be written is said by sh, and Hyprland still
-- exits. The QML is root's, and nothing edits it under a running greeter,
-- so the file watcher is off.
--
-- Hyprland sends what it starts to /dev/null, so the greeter's output,
-- with a line as it starts and as it ends, goes to the journal through
-- systemd-cat, under tide-greeter like the rest of the greeter's log.
-- Without systemd-cat it's lost, as before.
local function greeter_command(qml, status_file)
    local body
    if qml == nil then
        body = "echo 'tide-greeter: no TIDE_GREETER_QML, so no greeter to run'"
    else
        body = "echo 'tide-greeter: starting the greeter (qs)'; "
            .. "QS_DISABLE_FILE_WATCHER=1 qs -p " .. quote(qml) .. "; status=$?; "
            .. 'echo "tide-greeter: the greeter (qs) exited $status"'
        if status_file ~= nil then
            body = body .. '; echo "$status" >' .. quote(status_file)
        end
    end
    return "if command -v systemd-cat >/dev/null 2>&1; then { " .. body
        .. "; } 2>&1 | systemd-cat --identifier=tide-greeter; else " .. body .. "; fi; " .. EXIT
end

-- The pointer starts in the middle of the focused monitor, by the field,
-- not at Hyprland's top left corner, where it's easy to miss. `mode` is the
-- monitor's size in the layout's units, scaled and turned. A monitor that
-- can't be read leaves the pointer where it is, and says so.
local function center_pointer()
    local mon = hl.get_active_monitor()
    if mon == nil then
        error("no monitor yet")
    end
    hl.dispatch(hl.dsp.cursor.move({
        x = mon.x + math.floor(mon.mode.width / 2),
        y = mon.y + math.floor(mon.mode.height / 2),
    }))
end

hl.on("hyprland.start", function()
    hl.exec_cmd(greeter_command(env("TIDE_GREETER_QML", nil), env("TIDE_GREETER_QS_STATUS", nil)))
    local ok, err = pcall(center_pointer)
    if not ok then
        print("tide-greeter: couldn't center the pointer: " .. tostring(err))
    end
end)

-- Everything below is after the greeter is registered, and each is tried
-- alone: a setting this Hyprland doesn't take is said in the journal and
-- skipped, so it can't cost the greeter.
local function try(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        print("tide-greeter: " .. what .. ": " .. tostring(err))
    end
end

try("monitors", function()
    hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
end)

-- One section at a time, so one that fails leaves the others.
for name, section in pairs({
    input = {
        kb_layout = env("TIDE_GREETER_KB_LAYOUT", "us"),
        kb_model = env("TIDE_GREETER_KB_MODEL", ""),
        kb_variant = env("TIDE_GREETER_KB_VARIANT", ""),
        kb_options = env("TIDE_GREETER_KB_OPTIONS", ""),
    },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        -- Black until the greeter draws, like the lock's background.
        background_color = "rgb(000000)",
        -- The greeter runs Hyprland directly: greetd restarts it if it dies,
        -- so start-hyprland's watchdog has nothing to add.
        disable_watchdog_warning = true,
        disable_hyprland_guiutils_check = true,
        -- The greeter turns the displays off when no one's there (SPEC.md
        -- §11); a key or a move turns them back on, before the greeter
        -- hears of it.
        key_press_enables_dpms = true,
        mouse_move_enables_dpms = true,
    },
    ecosystem = {
        no_update_news = true,
        no_donation_nag = true,
    },
    animations = {
        enabled = false,
    },
    -- Hyprland's own log is a file in the greeter user's runtime
    -- directory, which goes once someone logs in; on stdout, it's kept in
    -- greetd's journal, where the greeter's trouble can be read later.
    debug = {
        enable_stdout_logs = true,
        colored_stdout_logs = false,
    },
}) do
    try("settings " .. name, function()
        hl.config({ [name] = section })
    end)
end
