-- The tide greeter's compositor (tide SPEC.md §11): Hyprland with nothing
-- in it but the greeter. greetd runs `tide-greeter` as its greeter user,
-- which runs Hyprland with this file. Every monitor gets its preferred
-- mode, the keyboard is the system's, none of Hyprland's own popups show,
-- and there are no key bindings: Hyprland's built-in VT switch is the only
-- key it acts on. It runs one program, the greeter, and exits when the
-- greeter does, which is once greetd has the session to start; greetd
-- then starts it.
--
-- tide-greeter passes what this needs in the environment:
--   TIDE_GREETER_QML      the greeter's QML (share/tide/shell/greeter.qml)
--   TIDE_GREETER_KB_LAYOUT, TIDE_GREETER_KB_MODEL,
--   TIDE_GREETER_KB_VARIANT, TIDE_GREETER_KB_OPTIONS
--                         localed's X11 keymap; unset, Hyprland's defaults

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
-- exit, however Quickshell ends. greetd starts the greeter again if it
-- ended without choosing a session. The QML is root's, and nothing edits it
-- under a running greeter, so the file watcher is off.
local function greeter_command(qml)
    if qml == nil then
        return "echo 'tide-greeter: no TIDE_GREETER_QML, so no greeter to run' >&2; " .. EXIT
    end
    return "QS_DISABLE_FILE_WATCHER=1 qs -p " .. quote(qml) .. "; " .. EXIT
end

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.config({
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
    },
    ecosystem = {
        no_update_news = true,
        no_donation_nag = true,
    },
    animations = {
        enabled = false,
    },
})

hl.on("hyprland.start", function()
    hl.exec_cmd(greeter_command(env("TIDE_GREETER_QML", nil)))
end)
