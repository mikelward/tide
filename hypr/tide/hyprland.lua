-- tide's Hyprland config as it comes, with none of your changes
-- (README.md beside it). `make install` puts it in ~/.config/hypr/tide/.
-- The tide session runs Hyprland with it while there's no
-- ~/.config/hypr/hyprland.lua; that file can be this one line:
--
--     dofile(os.getenv("HOME") .. "/.config/hypr/tide/hyprland.lua")
--
-- It returns tide's config module, set up, for tide.override().
local dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
return dofile(dir .. "config.lua").setup()
