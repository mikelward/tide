-- tide focus guard for Hyprland 0.56+ (SPEC.md §14).
--
-- Nothing steals the keyboard. A catch-all `no_initial_focus` rule opens
-- every window unfocused, and the guard then focuses the ones you asked for:
--
--   * a new window from the app you're in (a dialog, a second window);
--   * the first window of an app you just launched, or that app activating
--     a window it already had, while its one-shot launch grant holds.
--
-- Anything else stays where it opened, dimmed, and is announced on the event
-- socket as `custom>>tide-attention>>ADDRESS` for the shell to mark.
-- Lua can't set Hyprland's urgent flag, so the guard also keeps these
-- windows itself. Until a shell has marked them (it calls `set_order`, as
-- tide's Quickshell bar does at startup; waybar never does), each
-- also shows a Hyprland notification (`notify`).
--
-- `tide_focus.focus_attention()` (Super+Tab) goes to the latest
-- marked window: one the guard kept waiting, an activation without a grant,
-- or one the shell marks for a notification. The shell sees every kind, so
-- its order rules (`set_order`); without a shell, the guard's own does.
-- Pressed again
-- while Super is held, it steps to the next one, Alt+Tab style, without
-- clearing anything; `end_cycle()`, bound to Super's release, clears only
-- the window it landed on. The shell hears the cycle as
-- `custom>>tide-cycle>>start` and `custom>>tide-cycle>>end>>ADDRESS`,
-- and keeps its marks while the cycle steps through them.
-- If the guard itself fails, windows still open unfocused: the failure mode
-- is "never steals", not "always steals".
--
-- Usage, from hyprland.lua:
--
--   local focus = dofile(os.getenv("HOME") .. "/.config/hypr/tide/focus.lua")
--   focus.setup({})
--
-- setup() also publishes the module as the global `tide_focus`, so
-- `tide launch` can record a grant with
-- `hyprctl eval 'tide_focus.grant("APP")'` (or a list of the classes the
-- app's window may have, `tide_focus.grant({ "APP", "OTHER" })`; options
-- after the pid and key, `{ new_workspace = true }` for a launch on an
-- empty workspace), and a
-- notification click `tide_focus.grant_or_recent("APP")`.
--
-- Known gaps, from SPEC.md §14.3: Lua sees key presses but not pointer
-- buttons, so a click inside the window you're already in doesn't cancel a
-- grant; a grant names an app by window class, which the launcher reads
-- from its desktop entry, but a program name from a key binding or the
-- terminal isn't yet resolved through desktop entries; and a window that asked for fullscreen as it opened comes up
-- tiled, since Hyprland skips that request for a window it doesn't focus
-- and Lua can't see the request to re-apply it (TODO.md).

local M = {}

M.defaults = {
    -- How long a launch grant holds, in seconds.
    grant_seconds = 10,
    -- Show a Hyprland notification for each window left waiting, until a
    -- shell that marks them has called set_order.
    notify = true,
    -- Window classes of polkit agents. Their password prompt takes focus
    -- when you pressed a key in the last prompt_seconds, since that's you
    -- running `pkexec` or pressing a button that asks (SPEC.md §14.1);
    -- otherwise it waits like any other window. The Quickshell agent (M3)
    -- replaces this.
    prompt_classes = {
        "hyprpolkitagent",
        "polkit-gnome-authentication-agent-1",
        "org.kde.polkit-kde-authentication-agent-1",
    },
    prompt_seconds = 2,
    -- Window classes of xdg-desktop-portal backends. Their dialogs (the file
    -- chooser) are for the app you're in (SPEC.md §14.1), but they run in the
    -- backend's process, and Lua can't see the dialog's parent window. So one
    -- takes focus whenever a window is focused.
    portal_classes = {
        "xdg-desktop-portal-gtk",
        "xdg-desktop-portal-kde",
        "xdg-desktop-portal-gnome",
    },
}

-- Hyprland's focus reason for a window focused as it opens
-- (eFocusReason in desktop/state/FocusState.hpp: a plain enum, not flags).
local REASON_NEW_WINDOW = 16

local state = {
    opts = nil,
    -- { app = normalized id, at = seconds, pid = requester or nil, live },
    -- where live drops to false when the grant is used or canceled.
    grants = {},
    active = nil, -- { address, pid, app } of the focused window
    waiting = {}, -- addresses of windows left unfocused, oldest first
    shell_order = nil, -- every marked window, oldest first, from the shell
    cycle = nil, -- { list = { addresses }, i = index } while Super+Tab steps
}

-- The clock is a field so the tests can drive it.
M.clock = os.time
-- Where process parents are read from; a field so the tests can fake it.
M.proc = "/proc"

-- An app id as a grant or a window class might spell it, normalized:
-- lowercase and without a `.desktop` suffix.
local function normalize(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    id = id:lower():gsub("%.desktop$", "")
    return id ~= "" and id or nil
end
M.normalize = normalize

-- Whether two normalized ids name the same app. Qualified ids must match in
-- full, so `org.example.chat` and `com.example.chat` stay apart; a bare name
-- matches the last part of a qualified one, so `nautilus` (a command's
-- basename) matches `org.gnome.nautilus`.
local function same_id(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local a_bare, b_bare = not a:find(".", 1, true), not b:find(".", 1, true)
    if a_bare == b_bare then
        return false
    end
    local bare, qualified = a, b
    if b_bare then
        bare, qualified = b, a
    end
    return qualified:match("([^.]+)$") == bare
end
M.same_id = same_id

-- Field reads on Hyprland objects can fail for windows that are going away;
-- a failed read is treated as absent, as in layout.lua.
local function field(obj, key)
    local ok, v = pcall(function()
        return obj[key]
    end)
    return ok and v or nil
end

local function app_of(w)
    return normalize(field(w, "class")) or normalize(field(w, "initial_class"))
end

local function active_record(w)
    return { address = field(w, "address"), pid = field(w, "pid"), app = app_of(w) }
end

local function expire()
    local now = M.clock()
    local keep = {}
    for _, g in ipairs(state.grants) do
        if now - g.at <= state.opts.grant_seconds then
            table.insert(keep, g)
        end
    end
    state.grants = keep
end

-- Whether grant g names w's app, under any of the classes it lists.
local function names(g, app)
    for _, id in ipairs(g.apps or {}) do
        if same_id(id, app) then
            return true
        end
    end
    return false
end

-- Uses up the grant for w's app, if one holds, and returns it.
-- A grant for "*" is used by whichever app shows a window first; one that
-- names w's app is used before it.
local function take_grant(w)
    expire()
    local app = app_of(w)
    for _, wildcard in ipairs({ false, true }) do
        for i, g in ipairs(state.grants) do
            if (g.app == "*") == wildcard and (wildcard or names(g, app)) then
                g.live = false
                table.remove(state.grants, i)
                return g
            end
        end
    end
    return nil
end

-- A process's parent, from /proc/PID/stat, or nil if it can't be read (the
-- process is gone, or /proc isn't there). The command name in the second
-- field may hold spaces and parentheses, so the parent pid is read after
-- the last ')'.
local function parent_of(pid)
    local f = io.open(M.proc .. "/" .. pid .. "/stat", "r")
    if not f then
        return nil -- a process that has exited has no parent to walk
    end
    local stat = f:read("l")
    f:close()
    local ppid = stat and stat:match("^.*%)%s+%S+%s+(%d+)")
    return ppid and tonumber(ppid)
end

-- Whether pid is ancestor or descends from it, walking at most 64 parents.
-- A command the shell ran with `exec` replaced the shell, so its window
-- carries the shell's own pid.
local function descends(pid, ancestor)
    if pid == ancestor then
        return true
    end
    for _ = 1, 64 do
        pid = parent_of(pid)
        if not pid or pid <= 1 then
            return false
        end
        if pid == ancestor then
            return true
        end
    end
    return false
end

-- The process-ancestry fallback (SPEC.md §14.3), for a command whose name
-- matches no window class, like a script that opens a window. Only a grant
-- that names the process that asked for it (the shell a terminal command
-- ran in) qualifies, and only for a window whose process descends from
-- that one; a launch grant names no process, so it can't be used this way.
local function take_grant_by_ancestry(w)
    expire()
    local pid = field(w, "pid")
    if not pid then
        return nil
    end
    for i, g in ipairs(state.grants) do
        if g.pid and descends(pid, g.pid) then
            g.live = false
            table.remove(state.grants, i)
            return g
        end
    end
    return nil
end

-- Anything you do after launching cancels every grant: a slow app mustn't
-- take focus from whatever you moved on to.
local function cancel_grants()
    for _, g in ipairs(state.grants) do
        g.live = false
    end
    state.grants = {}
end

local function same_app_as_active(w)
    local active = state.active
    if not active then
        return false
    end
    local pid = field(w, "pid")
    if pid and active.pid and pid == active.pid then
        return true
    end
    local app = app_of(w)
    return same_id(app, active.app)
end

local focusing = false
-- Set while Super+Tab's own dispatch focuses a window: the guard focusing
-- a dialog mid-cycle is focus moving another way, not a step.
local stepping = false

local function focus_address(address)
    -- The flag must drop even if building or sending the dispatch throws, or
    -- every later focus change would look like the guard's own.
    focusing = true
    local ok, err = pcall(function()
        hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
    end)
    focusing = false
    if not ok then
        error(err, 0)
    end
end

local function focus(w)
    local address = field(w, "address")
    if not address then
        return -- a window that is going away has no address, and needs no focus
    end
    focus_address(address)
end

-- Focuses a new window and takes it to an empty workspace on its monitor,
-- following it there: a launch asked for on a new workspace (Ctrl+Enter in
-- the launcher). It happens as the window opens, not before the app
-- starts, so nothing you do in between is overridden: a key press or focus
-- change cancels the grant, and the window then opens where you are,
-- unfocused, like any other. Both dispatches are the guard's own focusing.
local function focus_on_new_workspace(w)
    local address = field(w, "address")
    if not address then
        return
    end
    focusing = true
    local ok, err = pcall(function()
        hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
        hl.dispatch(hl.dsp.window.move({ workspace = "emptym", follow = true }))
    end)
    focusing = false
    if not ok then
        error(err, 0)
    end
end

-- An address as a table key: Hyprland writes 0x and lowercase hex, and the
-- shell may write it without the 0x.
local function key(address)
    local hex = tostring(address):lower():gsub("^0x", ""):gsub("^0+(.)", "%1")
    return hex
end

local function forget(address)
    for i = #state.waiting, 1, -1 do
        if key(state.waiting[i]) == key(address) then
            table.remove(state.waiting, i)
        end
    end
end

local function wait(w)
    local address = field(w, "address")
    if not address then
        return nil -- a window that is going away has nothing to mark
    end
    forget(address)
    table.insert(state.waiting, address)
    return address
end

local function announce(w)
    local address = wait(w)
    if not address then
        return
    end
    hl.dispatch(hl.dsp.event("tide-attention>>" .. address))
    -- A shell that marks waiting windows has said so by giving its order;
    -- one that stops after that leaves the guard quiet until a reload.
    if state.opts.notify and not state.shell_order then
        hl.notification.create({
            text = (field(w, "class") or "A window") .. " is waiting: Super+Tab to go there",
            duration = 5000,
            icon = "info",
        })
    end
end

-- Every marked window but the focused one, most recently marked first:
-- in the shell's order once it has given one. A waiting window the shell's
-- list doesn't have yet was announced since it last spoke, so it's newest.
local function targets()
    local seen, out = {}, {}
    local function add(address)
        local k = key(address)
        if not seen[k] and not (state.active and state.active.address and key(state.active.address) == k) then
            seen[k] = true
            table.insert(out, address)
        end
    end
    local listed = {}
    for _, address in ipairs(state.shell_order or {}) do
        listed[key(address)] = true
    end
    for i = #state.waiting, 1, -1 do
        if not listed[key(state.waiting[i])] then
            add(state.waiting[i])
        end
    end
    local order = state.shell_order or {}
    for i = #order, 1, -1 do
        add(order[i])
    end
    return out
end

local function unlist(address)
    local order = state.shell_order
    if order then
        for i = #order, 1, -1 do
            if key(order[i]) == key(address) then
                table.remove(order, i)
            end
        end
    end
end

local function cycle_event(text)
    hl.dispatch(hl.dsp.event("tide-cycle>>" .. text))
end

-- The cycle is over, on the window at `address` (nil for none): that one
-- isn't marked now, and the rest stay marked.
local function finish_cycle(address)
    state.cycle = nil
    if address then
        forget(address)
        unlist(address)
    end
    cycle_event("end>>" .. (address or ""))
end

local function class_in(w, classes)
    local app = app_of(w)
    for _, class in ipairs(classes) do
        if same_id(normalize(class), app) then
            return true
        end
    end
    return false
end

-- A polkit agent's prompt right after a key press (§14.1). Lua sees key
-- presses but not clicks, and not which process asked, so this is the
-- keyboard half of the rule: a prompt after a click waits for Super+Tab.
local function prompt_you_asked_for(w)
    if not state.last_key or M.clock() - state.last_key > state.opts.prompt_seconds then
        return false
    end
    return class_in(w, state.opts.prompt_classes)
end

-- A portal's file chooser opens for the app you're using. Lua can't see a
-- dialog's parent, so any portal dialog counts as the active app's.
local function portal_dialog_for_active(w)
    return state.active ~= nil and class_in(w, state.opts.portal_classes)
end

-- A new window: focus it if it's yours, else leave it and mark it.
function M.on_open(w)
    -- Grants first, so one is used up even when the window is from the app
    -- you are in (a second terminal from a terminal, or a script's window).
    local g = take_grant(w) or take_grant_by_ancestry(w)
    if g and g.new_workspace then
        focus_on_new_workspace(w)
    elseif g then
        focus(w)
    elseif same_app_as_active(w) or portal_dialog_for_active(w) or prompt_you_asked_for(w) then
        -- Focus moving to a window no grant asked for is moving on, even
        -- though the guard dispatches it: a dialog that follows a click
        -- Lua can't see is the click's only trace.
        cancel_grants()
        focus(w)
    else
        announce(w)
    end
end

-- Whether w hasn't mapped yet. `field` can't say, since it reads false as
-- absent; a failed read counts as mapped, as every window did before this.
local function unmapped(w)
    local ok, mapped = pcall(function()
        return w.mapped
    end)
    return ok and mapped == false
end

-- An existing window asked to be activated. Hyprland has already marked it
-- urgent (misc:focus_on_activate is off); a launch grant lets it through,
-- and otherwise it waits with the rest, so Super+Tab takes the latest of both.
function M.on_urgent(w)
    -- Chrome activates a new window before mapping it, and Hyprland reports
    -- that as urgent. The window can't take focus yet, and using the grant
    -- here would leave its window.open with none, so the open decides.
    if unmapped(w) then
        return
    end
    -- A grant asked for on a new workspace focuses an existing window where
    -- it is: moving a window you already had would be a surprise.
    if take_grant(w) then
        focus(w)
        return
    end
    -- Announced like a window the guard kept, without the notification:
    -- Hyprland's own urgent flag goes the moment Super+Tab steps onto the
    -- window, and the bar should keep the mark until the cycle ends there.
    local address = wait(w)
    if address then
        hl.dispatch(hl.dsp.event("tide-attention>>" .. address))
    end
end

function M.on_close(w)
    local address = field(w, "address")
    if not address then
        return
    end
    forget(address)
    unlist(address)
    local c = state.cycle
    if c then
        -- At or before the cycle's place, the next Tab goes to the window
        -- that took its place.
        for i = #c.list, 1, -1 do
            if key(c.list[i]) == key(address) then
                table.remove(c.list, i)
                if i <= c.i then
                    c.i = c.i - 1
                end
            end
        end
        if #c.list == 0 then
            finish_cycle(nil)
        elseif c.i < 1 then
            c.i = #c.list
        end
    end
end

-- Super+Tab: goes to the most recently marked window and returns true, or
-- false when none is marked, so the key can fall back to the last window.
-- Pressed again before end_cycle(), it steps to the next one, and wraps.
function M.focus_attention()
    local c = state.cycle
    if c then
        c.i = c.i % #c.list + 1
    else
        local list = targets()
        if #list == 0 then
            return false
        end
        cancel_grants() -- you chose another window
        c = { list = list, i = 1 }
        state.cycle = c
        cycle_event("start")
    end
    stepping = true
    local ok, err = pcall(focus_address, c.list[c.i])
    stepping = false
    if not ok then
        error(err, 0)
    end
    return true
end

-- Super released: the cycle stops on the window it reached, which is no
-- longer marked. Returns false when no cycle was running, which is every
-- other time Super is released.
function M.end_cycle()
    local c = state.cycle
    if not c then
        return false
    end
    finish_cycle(c.list[c.i])
    return true
end

-- Every marked window, oldest mark first, as the shell orders them: the
-- guard's announcements and the shell's notification marks (SPEC.md
-- §14.4), which only the shell sees together. Super+Tab follows this order
-- from then on, replacing the last list.
function M.set_order(addresses)
    if type(addresses) ~= "table" then
        error("tide_focus.set_order: expected a list of addresses, got " .. tostring(addresses), 2)
    end
    local order = {}
    for _, address in ipairs(addresses) do
        if type(address) ~= "string" or key(address) == "" then
            error("tide_focus.set_order: expected window addresses, got " .. tostring(address), 2)
        end
        table.insert(order, "0x" .. key(address))
    end
    state.shell_order = order
end

-- Announces every waiting window again, oldest first, without the
-- notification: the shell calls it when it starts, since a shell that
-- restarted missed the first announcements.
function M.announce_waiting()
    for _, address in ipairs(state.waiting) do
        hl.dispatch(hl.dsp.event("tide-attention>>" .. address))
    end
end

function M.on_active(w, reason)
    reason = reason or 0
    -- Focus on nothing (an empty workspace, the last window closed) means no
    -- app is "the one you're in" until something is focused again.
    local before = state.active
    state.active = w and active_record(w) or nil
    local address = state.active and state.active.address
    if state.cycle then
        if stepping then
            return -- Super+Tab stepping: nothing is cleared until Super is up
        end
        -- Focus went somewhere else mid-cycle (a click, or the guard focusing
        -- a dialog): the cycle ends there.
        finish_cycle(address)
    end
    if address then
        forget(address) -- however you got there, it isn't waiting now
    end
    -- Focus coming back to the window you were already in (the launcher
    -- closing) isn't moving on, and the guard's own focusing is flagged
    -- while it dispatches. Anything else is: the pointer, a key binding, a
    -- click, a workspace switch, and focus passing on after a window closes.
    local returned = address ~= nil and before ~= nil and before.address == address
    if focusing or returned or reason == REASON_NEW_WINDOW then
        return
    end
    cancel_grants()
end

function M.on_key(_, _, key_state)
    -- 1 is a press; releases (including the one after the launch key) don't
    -- count as moving on.
    if key_state == 1 then
        cancel_grants()
        state.last_key = M.clock()
    end
end

-- Records a one-shot grant for app, from `tide launch`, a
-- notification click, or tide-grant before each shell command.
-- pid, if given, is the process that asked (tide-grant passes its
-- shell's), which lets a window from it or one of its descendants use the
-- grant. With a pid, app may be nil: a command whose app the shell can't
-- name still gets its windows focused, through ancestry alone.
--
-- app may also be a list of ids, for an app whose window class isn't known
-- for sure (the launcher's desktop ID and program name, SPEC.md §14.3): a
-- window of any of them uses the one grant. "*" stands alone, since a
-- wildcard beside names would make the names meaningless.
--
-- opts, if given, is { new_workspace = true } for a launch on a new
-- workspace: the window that uses the grant goes to an empty workspace on
-- its monitor, and focus follows it (`tide launch --new-workspace`).
function M.grant(app, pid, key, opts)
    if pid ~= nil and (math.type(pid) ~= "integer" or pid <= 1) then
        error("tide_focus.grant: expected a process id, got " .. tostring(pid), 2)
    end
    if key ~= nil and (math.type(key) ~= "integer" or key <= 0) then
        error("tide_focus.grant: expected a positive integer key, got " .. tostring(key), 2)
    end
    local new_workspace = false
    if opts ~= nil then
        if type(opts) ~= "table" then
            error("tide_focus.grant: expected an options table, got " .. tostring(opts), 2)
        end
        for k, v in pairs(opts) do
            if k ~= "new_workspace" or type(v) ~= "boolean" then
                error("tide_focus.grant: " .. tostring(k) .. " is not an option (new_workspace takes true or false)", 2)
            end
        end
        new_workspace = opts.new_workspace == true
    end
    local apps = {}
    if type(app) == "table" then
        local count = 0
        for _ in pairs(app) do
            count = count + 1
        end
        for i = 1, count do
            local id = normalize(app[i])
            if not id or (id == "*" and count > 1) then
                error("tide_focus.grant: expected a list of app ids, got " .. tostring(app[i]) .. " at " .. i, 2)
            end
            table.insert(apps, id)
        end
        if count == 0 then
            error("tide_focus.grant: expected at least one app id", 2)
        end
    else
        local id = normalize(app)
        if not id and not (app == nil and pid) then
            error("tide_focus.grant: expected an app id, got " .. tostring(app), 2)
        end
        apps[1] = id
    end
    expire()
    table.insert(state.grants, {
        app = apps[1],
        apps = apps,
        at = M.clock(),
        pid = pid,
        key = key,
        new_workspace = new_workspace,
        live = true,
    })
end

-- Adds ids to the grant just recorded for app, while it still holds: one
-- from `tide launch` (no pid), or from tide-grant for the shell pid. The
-- grant goes in under the program's name first, so a key press or focus
-- change from then on cancels it; the other classes the app's window may
-- have, read from desktop entries, come here after. A grant canceled, used
-- or expired in between stays gone: extend() never makes one. key is the
-- one the grant went in with, the granting process's pid, so a slow lookup
-- for a launch that was canceled can't widen a later grant for the same
-- program.
function M.extend(app, ids, pid, key)
    if pid ~= nil and (math.type(pid) ~= "integer" or pid <= 1) then
        error("tide_focus.extend: expected a process id, got " .. tostring(pid), 2)
    end
    if math.type(key) ~= "integer" or key <= 0 then
        error("tide_focus.extend: expected the grant's key, got " .. tostring(key), 2)
    end
    local id = normalize(app)
    if not id or id == "*" then
        error("tide_focus.extend: expected an app id, got " .. tostring(app), 2)
    end
    if type(ids) ~= "table" then
        error("tide_focus.extend: expected a list of app ids, got " .. tostring(ids), 2)
    end
    local add = {}
    for i, v in ipairs(ids) do
        local n = normalize(v)
        if not n or n == "*" then
            error("tide_focus.extend: expected an app id at " .. i .. ", got " .. tostring(v), 2)
        end
        table.insert(add, n)
    end
    expire()
    for i = #state.grants, 1, -1 do
        local g = state.grants[i]
        if g.live and g.pid == pid and g.app == id and g.key == key then
            for _, n in ipairs(add) do
                local seen = false
                for _, have in ipairs(g.apps) do
                    seen = seen or have == n
                end
                if not seen then
                    table.insert(g.apps, n)
                end
            end
            return
        end
    end
end

-- The window of app focused most recently, or one never focused if none
-- has been; nil when app has no window. focus_history_id is 0 for the
-- window focused last and -1 for one never focused.
-- The most recently focused window of any of `apps` (a list of normalized
-- ids): a Chrome site open as an `--app` window in two profiles is two
-- classes, and a click on its notification brings up whichever was used last.
local function most_recent(apps)
    local names = table.concat(apps, ", ")
    -- A failed query is an error, which Hyprland logs as the timer's: the
    -- click then brings up nothing, and the log says why.
    local ok, windows = pcall(hl.get_windows)
    if not ok then
        error("tide focus: couldn't list windows to bring up " .. names .. ": " .. tostring(windows), 0)
    end
    if type(windows) ~= "table" then
        error("tide focus: hl.get_windows returned " .. type(windows) .. ", not a list", 0)
    end
    local best, best_id = nil, nil
    for _, w in ipairs(windows) do
        local mine = false
        for _, app in ipairs(apps) do
            mine = mine or same_id(app, app_of(w))
        end
        if mine and field(w, "address") then
            local id = field(w, "focus_history_id")
            id = (math.type(id) == "integer" and id >= 0) and id or math.huge
            if not best or id < best_id then
                best, best_id = w, id
            end
        end
    end
    return best
end

-- A notification's grant ran out unused (SPEC.md §9): the app sent no
-- activation and opened no window, and you did nothing else meanwhile.
-- Its most recent window comes up instead, on whatever workspace it is.
-- That is the grant expiring, so a grant expire() has already dropped from
-- the list (the timer ran late) still falls back here; only one used or
-- canceled doesn't.
local function lapse(g)
    if not g.live then
        return -- used, or canceled by you moving on
    end
    g.live = false
    for i, other in ipairs(state.grants) do
        if other == g then
            table.remove(state.grants, i)
            break
        end
    end
    local w = most_recent(g.apps)
    if w then
        focus(w)
    end
end

-- One app id or a list of them, as a list of normalized ids; an error,
-- named for `fn`, when one isn't an id.
local function app_ids(app, fn)
    local list = type(app) == "table" and app or { app }
    local ids = {}
    for i = 1, #list do
        local id = normalize(list[i])
        if not id or id == "*" then
            error("tide_focus." .. fn .. ": expected an app id, got " .. tostring(list[i]), 3)
        end
        table.insert(ids, id)
    end
    if #ids == 0 then
        error("tide_focus." .. fn .. ": expected an app id", 3)
    end
    return ids
end

-- A click on a notification center entry whose notification is gone (SPEC.md
-- §9, from `tide focus`): the app's most recently focused window (of any of
-- the apps, for a list) comes up
-- at once, on whatever workspace it is. An app with no window gets nothing,
-- which the log says.
function M.focus_recent(app)
    local ids = app_ids(app, "focus_recent")
    local w = most_recent(ids)
    if w then
        cancel_grants() -- you chose this window
        focus(w)
    else
        print("tide focus: no window of " .. table.concat(ids, ", ") .. " to bring up")
    end
end

-- A clicked notification's grant (SPEC.md §9, from `tide grant`): a
-- grant like any other, which, if nothing uses or cancels it before it
-- runs out, focuses the app's most recently focused window. `app` can be a
-- list, any of whose windows the grant covers.
function M.grant_or_recent(app)
    local ids = app_ids(app, "grant_or_recent")
    expire()
    local g = { app = ids[1], apps = ids, at = M.clock(), live = true }
    table.insert(state.grants, g)
    hl.timer(function()
        lapse(g)
    end, { timeout = state.opts.grant_seconds * 1000, type = "oneshot" })
end

-- For the tests and `tide doctor`.
function M.grants()
    expire()
    local out = {}
    for _, g in ipairs(state.grants) do
        table.insert(out, (g.apps and #g.apps > 0) and table.concat(g.apps, " ") or g.app or ("pid " .. g.pid))
    end
    return out
end

function M.setup(opts)
    opts = opts or {}
    local merged = {}
    for k, v in pairs(M.defaults) do
        merged[k] = v
    end
    for k, v in pairs(opts) do
        if M.defaults[k] == nil then
            error("tide focus.setup: " .. tostring(k) .. " is not an option", 2)
        end
        -- NaN fails `v > 0`, and infinity would never expire.
        if type(v) ~= type(M.defaults[k]) or (type(v) == "number" and not (v > 0 and v < math.huge)) then
            local want = type(M.defaults[k]) == "number" and "a positive number" or "a " .. type(M.defaults[k])
            error("tide focus.setup: " .. tostring(k) .. " must be " .. want, 2)
        end
        if type(v) == "table" then
            -- n keys, each of 1..n present, means exactly 1..n; `#` alone
            -- can't say that, since a table with gaps has no defined length.
            local count = 0
            for _ in pairs(v) do
                count = count + 1
            end
            for i = 1, count do
                if v[i] == nil then
                    error("tide focus.setup: " .. tostring(k) .. " must be a list, with no keys or gaps", 2)
                end
            end
            for i = 1, count do
                local item = v[i]
                if type(item) ~= "string" or item == "" then
                    error("tide focus.setup: " .. tostring(k) .. " must list window classes", 2)
                end
            end
        end
        merged[k] = v
    end
    state.opts = merged
    state.last_key = nil
    state.grants = {}
    state.active = nil
    state.waiting = {}
    state.shell_order = nil
    state.cycle = nil
    local w = hl.get_active_window()
    if w then
        state.active = active_record(w)
    end

    hl.window_rule({ name = "tide-focus-guard", match = { class = ".*" }, no_initial_focus = true })
    hl.on("window.open", M.on_open)
    hl.on("window.urgent", M.on_urgent)
    hl.on("window.active", M.on_active)
    hl.on("window.close", M.on_close)
    hl.on("input.keyboard.key", M.on_key)
    _G.tide_focus = M
    return M
end

return M
