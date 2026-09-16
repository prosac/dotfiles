-- Hyprland config (Lua). Shared by the "Hyprland" and "Hyprland (DMS)" sessions.
--
-- Ported from hyprland.conf on 2026-09-16. Why Lua: DankMaterialShell 1.6 only
-- writes Lua fragments (dms/binds-user.lua, dms/layout.lua, dms/outputs.lua,
-- ...) and keeps its Settings pages read-only ("Hyprland conf mode") for as long
-- as the active config is hyprlang. Hyprland picks hyprland.lua over
-- hyprland.conf when both exist.
--
-- ⚠️ THE RUNTIME IPC CHANGES WITH THE FORMAT. Under a Lua config Hyprland refuses
-- `hyprctl keyword` outright ("keyword can't work with non-legacy parsers. Use
-- eval.") and `hyprctl dispatch` takes a Lua dispatcher expression, not the old
-- `dispatch <name> <args>` form. Every script that drives the compositor was
-- ported with this file:
--   hyprctl keyword general:gaps_in 5    ->  hyprctl eval 'hl.config({ general = { gaps_in = 5 } })'
--   hyprctl keyword workspace "3, ..."   ->  hyprctl eval 'hl.workspace_rule({ workspace = "3", ... })'
--   hyprctl dispatch dpms on             ->  hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'
-- `hl.workspace_rule` for a workspace that already has a rule MERGES into it
-- (verified), so re-issuing one per event does not pile up duplicates. `hl.bind`
-- on a key that is already bound does NOT replace it — both binds fire — so
-- rebinding needs an `hl.unbind` first.
--
-- Reference: /usr/share/hypr/hyprland.lua (upstream example) and
-- /usr/share/hypr/stubs/hl.meta.lua (the full API, for an LSP).

local home = os.getenv("HOME")
local hypr = (os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")) .. "/hypr"

local function exists(rel)
    local f = io.open(hypr .. "/" .. rel, "r")
    if f then f:close() end
    return f ~= nil
end

-- The DMS session is `hyprland-dms.desktop`; GDM exports its basename as
-- DESKTOP_SESSION and uwsm hands that through to the compositor. Everything
-- DMS-specific below is gated on it, so the default session never loads a DMS
-- fragment or a DMS keybind.
local dms_session = os.getenv("DESKTOP_SESSION") == "hyprland-dms"


------------------
---- MONITORS ----
------------------

-- nwg-displays writes BOTH monitors.conf and monitors.lua on every save; this
-- reads the .lua. Per-machine (in .chezmoiignore) and seeded on a fresh machine
-- by run_onchange_after_init-hypr-monitors.sh. Guarded anyway: a `require` of a
-- missing module is a Lua error, and an error aborts the REST OF THIS FILE — a
-- far worse failure than a monitor coming up on Hyprland's defaults.
if exists("monitors.lua") then
    require("monitors")
end

-- Window -> workspace routing. NOT named workspaces.lua: nwg-displays owns that
-- name (it writes workspaces.lua next to monitors.lua when you assign workspaces
-- in its UI) and would clobber it wholesale.
require("app-workspaces")


---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "ghostty"
local fileManager = "dolphin"
local menu        = "walker"


-------------------
---- AUTOSTART ----
-------------------

-- Top-level exec_cmd runs on EVERY config evaluation, i.e. at startup and on each
-- reload — the Lua equivalent of hyprlang's `exec =`. Work that must happen once
-- per session goes in the hyprland.start handler below (`exec-once =`).

-- Setup persistent workspaces, monitor pinning, and display names.
-- (setup_workspaces.sh handles renames internally — see comments there.)
hl.exec_cmd(hypr .. "/setup_workspaces.sh")

hl.on("hyprland.start", function()
    -- Keep workspace pinning in sync with the connected monitors so workspaces
    -- re-pin + migrate when HDMI / DP monitors come and go — without a Hyprland
    -- reload. Level-triggered (reconciles against the actual monitor set, with a
    -- periodic safety-net), so a dropped monitoradded edge — e.g. from a Meet
    -- screen-share output churn or dock/undock — self-heals instead of leaving
    -- the layout stuck undocked.
    hl.exec_cmd(hypr .. "/monitor-hotplug.py")

    -- Reading-column daemon. Two behaviours (see the script's docstring):
    --   * AUTO — a single tiled window on a WIDE monitor (>= 2000px logical, i.e.
    --     the ultrawide, not the 1440px laptop) is centered into a ~1250px column.
    --     The laptop keeps normal small gaps for a lone window.
    --   * MANUAL reading mode — Super+C (below) toggles a narrow ~800px column on
    --     the focused workspace, on any monitor, for focused reading.
    -- Resets to normal tiling for 0 or 2+ windows. Native w[tv1] smart-gaps can't
    -- do this (fixed px would break the narrow laptop), hence the socket2
    -- listener. See the reading-column note in ~/Documents/docs/.
    hl.exec_cmd(hypr .. "/reading-column.py")

    -- hyprtasking — workspace overview plugin (Super+Tab). Built from UPSTREAM
    -- raybbian/hyprtasking against the packaged hyprland-devel headers; the source
    -- is cloned into ~/.local/src/hyprtasking by hyprtasking-rebuild itself, so a
    -- fresh machine needs no manual checkout.
    --
    -- WHY NOT hyprpm: hyprpm builds HYPRLAND ITSELF from source to get headers, so
    -- it wants the compositor's full BuildRequires set (59 entries) and recompiles
    -- it on every `hyprpm update` after a version bump. Against packaged headers
    -- this costs one package (hyprland-devel) and compiles only the plugin. Tried
    -- on 2026-09-02: hyprpm cloned 208 MB into /run — tmpfs, i.e. RAM — then failed
    -- cmake configure on a missing glslang, with 58 more BuildRequires behind it.
    --
    -- ⚠️ Hyprland plugins are ABI-pinned to the exact compositor build. EVERY
    -- Hyprland update needs a rebuild against the new headers, or the load fails
    -- and the overview is silently gone. `--ensure` loads the existing build and
    -- rebuilds ONLY if it will not load, so a normal login compiles nothing.
    -- (After a routine `dnf update` bumped hyprland 0.56.2-1 -> -2 on 2026-08-31
    -- the .so stopped loading; a notification asking for a manual rebuild is not
    -- a fix.) See ~/Documents/docs/hyprland-hyprtasking-plugin.md
    hl.exec_cmd(home .. "/.local/bin/hyprtasking-rebuild --ensure")

    -- Apply current color-scheme to Hyprland borders + waybar CSS at startup
    -- so the visual state matches gsettings on every login.
    hl.exec_cmd(home .. "/.local/bin/toggle-color-scheme --apply")
end)

-- swayosd-server runs as a systemd user service (swayosd.service), bound to
-- graphical-session.target, so it is not started here.

-- Wallpaper: the awww daemon and wallpaper restore run as systemd user services
-- (awww.service + waypaper.service). waypaper.service is ordered After=awww.service,
-- and awww.service only reports active once its socket answers, so the daemon is
-- guaranteed ready before `waypaper --restore` sets the image (no sleep race).
-- Super+W opens the waypaper GUI. Terra's awww Obsoletes swww without Providing
-- it, so there is no swww binary; waypaper's native `awww` backend is used rather
-- than /usr/local/bin shims, which gave one daemon two names and let waypaper
-- start a second one on top of this unit. See awww.service for that failure.
-- See ~/Documents/docs/hyprland-wallpaper-waypaper-setup.md


-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- Make Qt apps follow the GTK theme, so they flip with toggle-color-scheme like
-- everything else. The qgtk3 platform theme plugin ships with Fedora's qt5/qt6
-- base packages (libqgtk3.so) — no qt5ct/qt6ct/Kvantum needed. Mirrored in the
-- niri session's `environment` block; ~/.config/environment.d/ would NOT work,
-- since Hyprland is started by GDM rather than by systemd.
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")

-- NB: a DisplayLink dock (Dell D6000) needs an AQ_DRM_DEVICES env here so
-- aquamarine enumerates the evdi DRM nodes — but ONLY set it together with
-- loading evdi at boot, and test it before relying on it. Deliberately left
-- out: the dock's monitor works without it (Hyprland hot-adds the evdi device
-- via udev), and evdi takes card0, so a wrong value risks a broken session at
-- login.
--
-- ⚠️ The DisplayLink stack was REMOVED on 2026-08-12 — `modinfo evdi` now reports
-- no such module, so nothing here is live. It went because evdi was the one
-- variable unique to the boot that deadlocked the compositor, and a resident
-- evdi holding imported amdgpu buffers could not be ruled out. Note that
-- `rm /etc/modules-load.d/evdi.conf` does NOT unload a running module — that is
-- what made the question unanswerable at the time.
--
-- Revival recipe (and the evdi caveat above, which still applies) is kept in
-- ~/Documents/docs/displaylink-dock-d6000-hyprland.md
-- Why it was removed: ~/Documents/docs/hyprland-freeze-atomic-commit-deadlock.md


-----------------------
---- LOOK AND FEEL ----
-----------------------

-- Sun/SGI/AIX-era workstation palette: dusty steel-blue → desaturated teal.
-- toggle-color-scheme re-applies the border and groupbar colors per scheme via
-- `hyprctl eval`, so these are only the dark-scheme starting values.
local accent_gradient = { colors = { "rgba(6b7a99ee)", "rgba(5c9090ee)" }, angle = 45 }

hl.config({
    general = {
        gaps_in  = 3,
        gaps_out = 8,

        border_size = 2,

        col = {
            active_border   = accent_gradient,
            inactive_border = "rgba(44444488)",
        },

        -- Resize windows by clicking and dragging on borders and gaps
        resize_on_border = true,
        extend_border_grab_area = 15,

        -- Please see https://wiki.hypr.land/Configuring/Advanced-and-Cool/Tearing/ before you turn this on
        allow_tearing = false,

        layout = "dwindle",
    },

    decoration = {
        rounding = 4,

        -- Change transparency of focused and unfocused windows
        active_opacity   = 1.0,
        inactive_opacity = 1.0,

        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = "rgba(1a1a1aee)",
        },

        blur = {
            enabled  = true,
            size     = 3,
            passes   = 1,
            vibrancy = 0.1696,
        },
    },

    -- Tabbed window groups (Super+T). SGI/Sun hard-edge workstation styling:
    -- square boxy tabs, steel-blue→teal gradient on the active tab, a crisp 3px
    -- indicator line, monospace labels, zero rounding everywhere.
    group = {
        -- Border of the grouped (parent) window — mirrors the general border palette.
        col = {
            border_active   = accent_gradient,
            border_inactive = "rgba(44444488)",
        },

        groupbar = {
            enabled          = true,
            font_family      = "monospace",
            font_size        = 10,
            height           = 18,
            indicator_height = 3,     -- crisp accent line under the active tab
            gradients        = true,
            render_titles    = true,
            scrolling        = true,  -- scroll over the bar to cycle tabs

            -- Hard edges — no rounding, no gaps. Pure boxy workstation look.
            rounding          = 0,
            gradient_rounding = 0,
            gaps_in           = 0,
            gaps_out          = 0,

            text_color = "rgba(e5e9f0ff)",
            col = {
                active   = accent_gradient,
                inactive = "rgba(2e3440dd)",
            },
        },
    },

    animations = {
        enabled = true,
    },

    -- See https://wiki.hypr.land/Configuring/Layouts/Dwindle-Layout/
    dwindle = {
        -- NB: `pseudotile` was removed in Hyprland 0.56 — pseudotiling no longer
        -- has a master switch, the pseudo dispatcher (mainMod + P below) just works.
        preserve_split = true,

        -- Keep new windows splitting side-by-side on the ultrawide.
        --
        -- Dwindle decides the split from the layout box: it stacks top/bottom as
        -- soon as `box.w <= box.h * split_width_multiplier`. Since 0.56 reworked
        -- the layout engine, gaps_out (including a per-workspace gaps_out rule) is
        -- subtracted from that box *before* the decision — it used to be applied
        -- per-window afterwards, leaving the box full-width. So reading-column.py's
        -- gaps_out of 24/1095/24/1095 makes the box ~1250x1366 on the 3440x1440
        -- screen — taller than wide — and the second window stacked full-width /
        -- half-height instead of splitting left/right.
        --
        -- 0.85 keeps the 1250px auto column (ratio ~0.91) on the side-by-side side
        -- of the threshold. preserve_split=true freezes the orientation chosen at
        -- open time, so this is decided once per pair. The narrow 800px Super+C
        -- reading column (ratio ~0.59) is still below the threshold and will
        -- stack — fix that case by hand with the togglesplit bind below.
        split_width_multiplier = 0.85,
    },

    master = {
        new_status = "master",
    },

    misc = {
        force_default_wallpaper = -1,    -- Set to 0 or 1 to disable the anime mascot wallpapers
        disable_hyprland_logo   = false, -- If true disables the random hyprland logo / anime girl background. :(
    },
})

-- Default curves and animations, see https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/
hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1}    } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1}    } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1}       } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1}    } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1}     } })

hl.animation({ leaf = "global",        enabled = true, speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",        enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",       enabled = true, speed = 4.79, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn",     enabled = true, speed = 4.1,  bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut",    enabled = true, speed = 1.49, bezier = "linear",       style = "popin 87%" })
hl.animation({ leaf = "fadeIn",        enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade",          enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers",        enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn",      enabled = true, speed = 4,    bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.5,  bezier = "linear",       style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })

-- "Smart gaps" / "No gaps when only" is deliberately NOT used: single-window
-- centering is handled by reading-column.py (hyprland.start above) because it
-- needs per-monitor computed margins, which fixed-px w[tv1] rules can't express.
-- Don't enable both.

-- hyprtasking (workspace overview, Super+Tab — see hyprland.start above).
-- `plugin.hyprtasking.*` keys do not exist until the plugin has registered them,
-- and setting an unknown key is a config error on every login. The guard makes
-- this block a no-op on the first evaluation; loading the plugin triggers a
-- config reload, and on that pass the table exists and the block applies.
-- (Verified: `hyprctl plugin load` -> reload -> `plugin:hyprtasking:jump:enabled`
-- reads 1.)
if hl.plugin.hyprtasking then
    hl.config({
        plugin = {
            hyprtasking = {
                layout = "grid",

                -- Type a workspace's label (1-9, 0, then a-z) to jump straight
                -- to it, instead of aiming with the mouse.
                jump = {
                    enabled = true,
                },
            },
        },
    })
end


---------------
---- INPUT ----
---------------

hl.config({
    input = {
        kb_layout  = "eu",
        kb_variant = "",
        kb_model   = "",
        kb_options = "ctrl:nocaps",
        kb_rules   = "",

        follow_mouse = 1,

        repeat_rate  = 50,   -- keys per second while held (default 25)
        repeat_delay = 250,  -- ms before repeat kicks in (default 600)

        sensitivity = 0, -- -1.0 - 1.0, 0 means no modification.

        natural_scroll = true,

        scroll_factor = 0.5, -- G502 X PLUS hi-res wheel scrolls too fast at 1.0

        touchpad = {
            natural_scroll = true,
        },

        -- Wacom Intuos BT M via OpenTabletDriver (see bootstrap/SETUP.md § 2c).
        -- Binds the pen to the laptop panel; without it Hyprland spreads the pen
        -- across the whole desktop layout, which is both distorted and partly dead
        -- (the layout is L-shaped, so the area below the ultrawide's right half
        -- maps to no screen at all).
        --
        -- ⚠️ This MUST be the global input.tablet.output. Setting `output` in a
        -- per-device block for opentabletdriver does NOT work on 0.56 — it is
        -- accepted with an empty `hyprctl configerrors` and then silently ignored.
        -- Verify with `hyprctl getoption input:tablet:output` (must say
        -- `set: true`), never by the absence of config errors. There is only one
        -- tablet — the kernel wacom device is muted by
        -- /etc/udev/rules.d/70-opentabletdriver.rules — so global is also correct.
        tablet = {
            output = "eDP-1",
        },
    },
})


---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER"

local function key(combo)
    return mainMod .. " + " .. combo
end

-- Core
hl.bind(key("Return"), hl.dsp.exec_cmd(terminal))
hl.bind(key("D"),      hl.dsp.exec_cmd(menu))
hl.bind(key("Space"),  hl.dsp.exec_cmd(menu))  -- macOS Spotlight-style launcher trigger

-- Workspace overview (hyprtasking): Tab alone = the monitor under the cursor,
-- +SHIFT = every monitor at once. Same key closes it again. Inside the overview:
-- right-click switches, left-drag moves a window, 1-9/0/a-z jump by label.
-- NB: no global Escape bind (which the plugin's README suggests) — even with
-- non_consuming it is one more thing between emacs/evil and terminals and their
-- Escape key.
--
-- A Lua function, not a dispatcher: the plugin registers hl.plugin.hyprtasking
-- only once it loads (from hyprland.start), and the function body resolves the
-- table at keypress, so nothing here is unresolved while the config is parsed.
-- This replaces hyprlang's `exec, hyprctl dispatch hyprtasking:toggle`
-- workaround for the parse-time "Invalid dispatcher" error overlay.
local function overview(mode)
    return function()
        if hl.plugin.hyprtasking then
            hl.plugin.hyprtasking.toggle(mode)
        end
    end
end
hl.bind(key("Tab"),         overview("cursor"))
hl.bind(key("SHIFT + Tab"), overview("all"))

-- kando pie menu — moved off Super+Tab for hyprtasking; keeps the launchers
-- together on Space (menu on Super+Space, kando on Super+SHIFT+Space).
hl.bind(key("SHIFT + Space"), hl.dsp.exec_cmd('kando -m "Example Menu"'))
hl.bind(key("Q"), hl.dsp.window.close())
-- Session menu (lock / log out / suspend / hibernate / reboot / shut down).
-- NOT hl.dsp.exit(): this session runs under uwsm, whose README says in as many
-- words not to use the compositor's native exit mechanism -- it yanks the
-- compositor out from under its clients and skips the ordered unit deactivation.
-- session-menu resolves the right teardown at runtime instead (uwsm stop here,
-- niri IPC there, loginctl terminate-session otherwise), so the same key is
-- correct in the default, DMS and niri sessions.
hl.bind(key("SHIFT + E"), hl.dsp.exec_cmd(home .. "/.local/bin/session-menu"))
hl.bind(key("E"), hl.dsp.exec_cmd(fileManager))
hl.bind(key("W"), hl.dsp.exec_cmd("waypaper"))  -- wallpaper picker GUI (awww backend)
hl.bind(key("F"), hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind(key("M"), hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind(key("V"), hl.dsp.window.float({ action = "toggle" }))
hl.bind(key("P"), hl.dsp.window.pseudo())  -- dwindle
hl.bind(key("Escape"), hl.dsp.exec_cmd("loginctl lock-session"))
hl.bind(key("SHIFT + Escape"), hl.dsp.exec_cmd("systemctl suspend"))
-- Packing away for the night or a weekend. The lid only ever suspends (~1 W, so
-- a closed machine still goes flat in under three days on this s2idle-only
-- laptop) -- hibernating is a deliberate act, taken while watching it power off.
-- It is deliberately NOT automatic: on 2026-08-12 an unattended timed hibernate
-- wedged inside a closed backpack and cooked the machine for 44 minutes.
hl.bind(key("CTRL + Escape"), hl.dsp.exec_cmd(home .. "/.local/bin/hibernate-now"))
hl.bind(key("SHIFT + T"), hl.dsp.exec_cmd(home .. "/.local/bin/toggle-color-scheme"))
hl.bind(key("G"), hl.dsp.exec_cmd(home .. "/.local/bin/term-project"))  -- fuzzy-pick a repo -> ghostty with project banner
hl.bind(key("C"), hl.dsp.exec_cmd(hypr .. "/reading-column.py toggle"))  -- toggle narrow reading column on focused workspace

-- Focus (vim hjkl)
hl.bind(key("H"), hl.dsp.focus({ direction = "l" }))
hl.bind(key("J"), hl.dsp.focus({ direction = "d" }))
hl.bind(key("K"), hl.dsp.focus({ direction = "u" }))
hl.bind(key("L"), hl.dsp.focus({ direction = "r" }))

-- Switch between current and last focused window
hl.bind(key("grave"), hl.dsp.focus({ last = true }))

-- Split orientation escape hatch. Super+O flips the focused pair between
-- side-by-side and stacked, Super+SHIFT+O swaps the two windows within the split.
-- See also hl.dsp.layout("preselect l|r|u|d"), which aims the *next* window
-- (one-shot unless dwindle.permanent_direction_override is on).
hl.bind(key("O"),         hl.dsp.layout("togglesplit"))
hl.bind(key("SHIFT + O"), hl.dsp.layout("swapsplit"))

-- Swap window with neighbor
hl.bind(key("SHIFT + H"), hl.dsp.window.swap({ direction = "l" }))
hl.bind(key("SHIFT + J"), hl.dsp.window.swap({ direction = "d" }))
hl.bind(key("SHIFT + K"), hl.dsp.window.swap({ direction = "u" }))
hl.bind(key("SHIFT + L"), hl.dsp.window.swap({ direction = "r" }))

-- Resize submap: Super+R enters, hjkl resize, Escape/Return exits
hl.bind(key("R"), hl.dsp.submap("resize"))
hl.define_submap("resize", function()
    hl.bind("H", hl.dsp.window.resize({ x = -40, y = 0,   relative = true }), { repeating = true })
    hl.bind("J", hl.dsp.window.resize({ x = 0,   y = 40,  relative = true }), { repeating = true })
    hl.bind("K", hl.dsp.window.resize({ x = 0,   y = -40, relative = true }), { repeating = true })
    hl.bind("L", hl.dsp.window.resize({ x = 40,  y = 0,   relative = true }), { repeating = true })
    hl.bind("escape", hl.dsp.submap("reset"))
    hl.bind("return", hl.dsp.submap("reset"))
end)

-- Switch workspaces with mainMod + [0-9]
-- Move active window to a workspace with mainMod + SHIFT + [0-9]
for i = 1, 10 do
    local k = tostring(i % 10)  -- 10 maps to key 0
    hl.bind(key(k),              hl.dsp.focus({ workspace = tostring(i) }))
    hl.bind(key("SHIFT + " .. k), hl.dsp.window.move({ workspace = tostring(i) }))
end

-- Special workspace (scratchpad)
hl.bind(key("S"),         hl.dsp.workspace.toggle_special("magic"))
hl.bind(key("SHIFT + S"), hl.dsp.window.move({ workspace = "special:magic" }))

-- Scroll through existing workspaces with mainMod + scroll
hl.bind(key("mouse_down"), hl.dsp.focus({ workspace = "e+1" }))
hl.bind(key("mouse_up"),   hl.dsp.focus({ workspace = "e-1" }))

-- Move/resize windows with mainMod + LMB/RMB and dragging
hl.bind(key("mouse:272"), hl.dsp.window.drag(),   { mouse = true })
hl.bind(key("mouse:273"), hl.dsp.window.resize(), { mouse = true })

-- Toggle grouped/tabbed state
hl.bind(key("T"), hl.dsp.group.toggle())

-- Change active tab (next/previous)
hl.bind(key("bracketright"), hl.dsp.group.next())
hl.bind(key("bracketleft"),  hl.dsp.group.prev())

-- Move window into group (CTRL = stronger than SHIFT swap)
hl.bind(key("CTRL + H"), hl.dsp.window.move({ into_group = "l" }))
hl.bind(key("CTRL + J"), hl.dsp.window.move({ into_group = "d" }))
hl.bind(key("CTRL + K"), hl.dsp.window.move({ into_group = "u" }))
hl.bind(key("CTRL + L"), hl.dsp.window.move({ into_group = "r" }))

-- Screenshots (grim + slurp + wl-clipboard)
hl.bind("Print",         hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd('grim -g "$(slurp)" ~/Pictures/$(date +%F-%H%M%S).png'))
hl.bind(key("Print"),    hl.dsp.exec_cmd("grim ~/Pictures/$(date +%F-%H%M%S).png"))

-- Laptop multimedia keys for volume and LCD brightness, with swayosd showing the
-- OSD on the focused monitor.
local function osd(args)
    return hl.dsp.exec_cmd(
        [[swayosd-client --monitor "$(hyprctl monitors -j | jq -r '.[] | select(.focused == true).name')" ]] .. args)
end
local locked_repeat = { locked = true, repeating = true }
hl.bind("XF86AudioRaiseVolume",  osd("--output-volume +5"),        locked_repeat)
hl.bind("XF86AudioLowerVolume",  osd("--output-volume -5"),        locked_repeat)
hl.bind("XF86AudioMute",         osd("--output-volume mute-toggle"), locked_repeat)
hl.bind("XF86AudioMicMute",      osd("--input-volume mute-toggle"),  locked_repeat)
hl.bind("XF86MonBrightnessUp",   osd("--brightness +10"),          locked_repeat)
hl.bind("XF86MonBrightnessDown", osd("--brightness -10"),          locked_repeat)

-- Requires playerctl
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })


--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

-- Workspace rules - configured dynamically via setup_workspaces.sh
-- based on connected monitors (HDMI-A-1 presence)

-- Ignore maximize requests from apps. You'll probably like this.
hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

-- Fix some dragging issues with XWayland
hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },
    no_focus = true,
})

-- Chromium notification popups — no app_id or title set by the browser
hl.window_rule({
    name  = "chromium-notification-popups",
    match = { class = "^$", title = "^$", xwayland = false },
    float    = true,
    pin      = true,
    move     = "100%-w-12 40",
    no_focus = true,
})

-- Kando radial menu — force fit to focused monitor (cursor's monitor via follow_mouse)
hl.window_rule({
    name  = "kando-menu",
    match = { class = "^(menu\\.kando\\.Kando)$", title = "^(Kando Menu)$" },
    float            = true,
    size             = "100% 100%",
    move             = "0 0",
    pin              = true,
    border_size      = 0,
    no_blur          = true,
    no_anim          = true,
    no_initial_focus = true,
    rounding         = 0,
})

-- Kando settings: half-size and centered. 0.56 removed the `monitor` MATCHER
-- (monitor is now only an effect), so this applies on every monitor. size is
-- relative to the monitor, so the result is the same shape on the internal
-- display too.
hl.window_rule({
    name  = "kando-settings",
    match = { class = "^(menu\\.kando\\.Kando)$", title = "^(Kando Settings)$" },
    float  = true,
    size   = "60% 70%",
    center = true,
})


-----------------------------
---- DMS SESSION ONLY ----
-----------------------------

-- Everything the "Hyprland (DMS)" session changes about the compositor lives
-- here, gated on dms_session (see the top of this file).
--
-- This block REPLACES ~/.local/bin/dms-binds (+ dms-binds.service), which
-- re-pointed these keys at runtime with `hyprctl keyword unbind/bind`. That
-- could not survive a Lua config (`keyword` is refused), and it never survived a
-- reload either -- the script had to sit on the event socket re-applying itself
-- after every `configreloaded`. Here the gate is re-evaluated on every reload,
-- so the binds simply are the config.
if dms_session then
    local function rebind(combo, cmd)
        hl.unbind(combo)  -- hl.bind alone would ADD a second bind; both would fire
        hl.bind(combo, hl.dsp.exec_cmd(cmd))
    end

    -- replacing existing binds (walker -> DMS spotlight)
    rebind(key("D"),     "dms ipc call spotlight toggle")
    rebind(key("Space"), "dms ipc call spotlight toggle")
    -- new keys, all free in the default session
    rebind(key("N"),         "dms ipc call notifications toggle")
    rebind(key("A"),         "dms ipc call control-center toggle")
    rebind(key("X"),         "dms ipc call powermenu toggle")
    rebind(key("SHIFT + V"), "dms ipc call clipboard toggle")
    rebind(key("slash"),     "dms ipc call keybinds toggle hyprland")
    -- Super+W MUST move off waypaper here. hyprland-dms masks awww.service in this
    -- session, but a mask cannot stop waypaper: its awww backend runs
    -- `pgrep awww-daemon` and, on an empty result, starts a daemon of its own
    -- (changer.py:change_with_awww). One keypress would put an unmanaged
    -- wallpaper daemon on top of DMS's own layer. `dash toggle wallpaper`, not the
    -- deprecated `dankdash wallpaper`.
    rebind(key("W"), "dms ipc call dash toggle wallpaper")

    -- DMS-owned fragments in ~/.config/hypr/dms/ (per-machine, not in chezmoi).
    -- Loaded LAST so what you set in DMS Settings wins over the values above.
    -- DMS decides whether a page is editable by grepping this file for the
    -- literal `require("dms.<name>")`, so keep that spelling -- wrapping it in an
    -- `if` is fine (verified with `dms config resolve-include`).
    --
    -- Not loaded: dms.colors (matugen is excluded at the dnf level and
    -- toggle-color-scheme owns the border colors) and dms.binds (DMS's stock
    -- keymap, which collides with half of the binds above). Your own edits in
    -- DMS's keybind editor go to dms/binds-user.lua, which IS loaded.
    if exists("dms/outputs.lua")     then require("dms.outputs")     end
    if exists("dms/layout.lua")      then require("dms.layout")      end
    if exists("dms/cursor.lua")      then require("dms.cursor")      end
    if exists("dms/windowrules.lua") then require("dms.windowrules") end
    if exists("dms/binds-user.lua")  then require("dms.binds-user")  end
end
