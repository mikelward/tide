-- The tide session's Hyprland config (SPEC.md §6.8): tide's, with your
-- options over its defaults, then the settings tide's shell writes, then
-- hyprland.local.lua. `make install` puts it beside tide's hyprland.lua,
-- and tide-hyprland starts Hyprland with it. Change your
-- ~/.config/hypr/hyprland.lua, not this file.
--
-- Yours gives your options (tide's hyprland.lua lists them): it returns
-- them as a table, or runs tide's hyprland.lua with them, as a config of
-- yours did before this file. Here, tide's hands them over rather than
-- running, and runs once, after, with them. So yours says only what it
-- changes, and one that's missing, broken or never loads tide's still
-- leaves tide's keys, layout and the settings pages' settings, with a
-- notification saying what went wrong. What else yours does, such as
-- hl.env, runs before tide's; a setting tide makes too belongs in
-- hyprland.local.lua, which runs after.
--
-- TIDE_HYPRLAND_LUA names another tide hyprland.lua, for tests.

local home = os.getenv("HOME") or ""
local config_home = os.getenv("XDG_CONFIG_HOME")
if config_home == nil or config_home == "" then
    config_home = home .. "/.config"
end
local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
local tide_path = os.getenv("TIDE_HYPRLAND_LUA")
if tide_path == nil or tide_path == "" then
    tide_path = here .. "/hyprland.lua"
end
local yours_path = config_home .. "/hypr/hyprland.lua"

local function notify_error(text)
    print("tide: " .. text)
    local ok, err = pcall(hl.notification.create, { text = text, duration = 15000, icon = "error" })
    if not ok then
        print("tide: couldn't show that as a notification: " .. tostring(err))
    end
end

-- Yours, run for its options alone: tide's hyprland.lua, run from it while
-- tide_session.collect is set, keeps them in tide_session.opts and returns.
local opts = {}
tide_session = { collect = true }
-- One that isn't there is no options; one that is but can't be opened
-- is said, as tide's defaults stand in for it. errno 2 is ENOENT.
local exists, open_err, code = io.open(yours_path, "r")
if not exists and code ~= 2 then
    notify_error("Your hyprland.lua couldn't be opened, so tide's defaults apply: " .. tostring(open_err))
elseif exists then
    exists:close()
    local chunk, load_err = loadfile(yours_path)
    if not chunk then
        notify_error("Your hyprland.lua didn't load, so tide's defaults apply: " .. tostring(load_err))
    else
        local ok, result = pcall(chunk)
        if not ok then
            notify_error("Your hyprland.lua failed, so tide's defaults apply"
                .. (tide_session.opts ~= nil and " with the options it gave" or "") .. ": " .. tostring(result))
            opts = tide_session.opts or opts
        elseif type(result) == "table" then
            opts = result
        elseif tide_session.opts ~= nil then
            opts = tide_session.opts
        end
    end
end
tide_session = nil

local chunk, load_err = loadfile(tide_path)
if not chunk then
    error("tide's hyprland.lua didn't load: " .. tostring(load_err) .. "; run `make install` in tide", 0)
end
chunk(opts)
