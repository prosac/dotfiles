-- Window → workspace routing rules. Loaded by hyprland.lua.
-- `workspace = "N silent"`: open on the target workspace without switching focus.
-- See workspace labels in setup_workspaces.sh.
--
-- Not called workspaces.lua: nwg-displays writes a file of that name next to
-- monitors.lua when workspaces are assigned in its UI, and would overwrite this.

-- 1:Web — browser (everything-web window: gmail, chat, prefect, etc.)
hl.window_rule({
    name  = "route-browser",
    match = { class = "^(chromium-browser|Chromium-browser|google-chrome|Google-chrome|firefox)$" },
    workspace = "1 silent",
})

-- 2:Code — emacs (org-mode notes live here too)
hl.window_rule({
    name  = "route-emacs",
    match = { class = "^(emacs)$" },
    workspace = "2 silent",
})

-- 5:All The Things — the all_the_things app under development
hl.window_rule({
    name  = "route-all-the-things",
    match = { class = "^(net\\.mediaparadise\\.AllTheThings)$" },
    workspace = "5 silent",
})
