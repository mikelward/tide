-- A workspace spanning every monitor (SPEC.md §6.5, Monitors): which
-- Hyprland workspace is each monitor's part of a tide workspace, what a
-- switch dispatches, and where windows go after a monitor goes away or comes
-- back. Pure, with no Hyprland API, so it tests in plain Lua; conf's keys
-- and the shell turn its answers into dispatches.
--
-- A Hyprland workspace is on one monitor, so each part is a workspace of
-- its own. The main monitor's part has the workspace's own name, so one
-- monitor works exactly as before. Each other monitor's part is
-- `NAME@OUT`, OUT being the monitor's connector, such as `DP-2`. A name
-- can't hold `@`, so the last `@` always starts the connector.
--
-- Monitors are their connector names, strings. `main` is the main
-- monitor's: the one showing the parts with plain names.

local M = {}

M.SEP = "@"

-- The Hyprland name of `name`'s part on `output`.
function M.part(name, output, main)
    if output == main then
        return name
    end
    return name .. M.SEP .. output
end

-- The workspace and the monitor a Hyprland workspace's name stands for:
-- `NAME@OUT` is NAME's part on OUT, and a plain name is the main
-- monitor's part, which gives nil for the monitor. A special workspace's
-- name (`special:...`) is no part of any, and gives nil.
function M.split(hypr_name)
    if type(hypr_name) ~= "string" or hypr_name == "" or hypr_name:find("^special:") then
        return nil
    end
    local name, output = hypr_name:match("^(.+)" .. M.SEP .. "([^" .. M.SEP .. "]+)$")
    if name then
        return name, output
    end
    return hypr_name, nil
end

-- The monitor a Hyprland workspace's part is meant for: its connector, or
-- `main` for a plain name. nil for a special workspace.
function M.output_of(hypr_name, main)
    local name, output = M.split(hypr_name)
    if not name then
        return nil
    end
    return output or main
end

-- Workspace rules binding each part of `name` to its monitor, the main
-- one's included, so a part Hyprland makes, from any monitor and by any
-- dispatch, is made there (`CWorkspaceStateTracker::create` honors a rule's
-- monitor). Without its rule, the main part made after a switch has shown
-- another monitor's part would land on that monitor, which has focus then.
-- Each is { workspace = "name:PART", monitor = OUT }, in `outputs`' order.
-- Adding a rule for a workspace that has one updates it, so a new main
-- monitor moves the plain parts' rules with it.
function M.rules(name, outputs, main)
    local rules = {}
    for _, output in ipairs(outputs) do
        rules[#rules + 1] = { workspace = "name:" .. M.part(name, output, main), monitor = output }
    end
    return rules
end

-- The parts to show to switch to `name`, one per monitor, as Hyprland
-- selectors, the focused monitor's last: showing a part on another
-- monitor focuses that monitor, so the last one shown keeps focus where it
-- was. Each is { output = OUT, workspace = "name:..." }.
function M.switch(name, outputs, main, focused)
    local plan, last = {}, nil
    for _, output in ipairs(outputs) do
        local step = { output = output, workspace = "name:" .. M.part(name, output, main) }
        if output == focused then
            last = step
        else
            plan[#plan + 1] = step
        end
    end
    if last then
        plan[#plan + 1] = last
    end
    return plan
end

local function present(outputs)
    local set = {}
    for _, output in ipairs(outputs) do
        set[output] = true
    end
    return set
end

-- Notes the monitor each of `windows` belongs on, for the windows `homes`
-- doesn't have yet, from the part it's in. `homes` maps a window's
-- address to its monitor and is kept for the session. Each window is
-- { address = ..., workspace = HYPRLAND_NAME }. A window in a part whose
-- monitor isn't there is left out: it was put there before tide knew it.
function M.note(homes, windows, outputs, main)
    local here = present(outputs)
    for _, w in ipairs(windows) do
        if homes[w.address] == nil then
            local output = M.output_of(w.workspace, main)
            if output and here[output] then
                homes[w.address] = output
            end
        end
    end
    return homes
end

-- A window moved to another monitor on purpose (`Super+Shift+Left` /
-- `Right`, a drag) belongs there from now on.
function M.moved(homes, address, output)
    homes[address] = output
    return homes
end

-- Forgets a window that closed.
function M.closed(homes, address)
    homes[address] = nil
    return homes
end

-- After a monitor goes away or comes back: the moves that put each of
-- `windows` in the part of its workspace on the monitor it belongs on, or
-- on the main monitor while that one isn't there. Each move is
-- { address = ..., workspace = "name:..." }, in `windows`' order; a
-- window already where it belongs gets none, and so does one in a special
-- workspace (a minimized one). Windows `homes` doesn't have are noted
-- first, from where they are.
function M.handoff(homes, windows, outputs, main)
    M.note(homes, windows, outputs, main)
    local here = present(outputs)
    local moves = {}
    for _, w in ipairs(windows) do
        local name = M.split(w.workspace)
        if name then
            local home = homes[w.address]
            local output = (home and here[home]) and home or main
            local target = M.part(name, output, main)
            if target ~= w.workspace then
                moves[#moves + 1] = { address = w.address, workspace = "name:" .. target }
            end
        end
    end
    return moves
end

return M
