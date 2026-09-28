# Force AutomaticLoginEnable=True / AutomaticLogin=<user> into the [daemon]
# section of GDM's /etc/gdm/custom.conf. Reads the current file on stdin and
# writes the corrected file to stdout; run it via `mise run bootstrap:gdm-autologin`.
#
# WHY THIS EXISTS RATHER THAN A CHEZMOI-MANAGED custom.conf
#
# custom.conf is an RPM %config file that gdm's own tooling and future package
# updates both write to (there is a /etc/gdm/custom.conf.rpmnew on this machine
# already). Shipping a whole file from the dotfiles would freeze whatever
# defaults Fedora ships today and silently drop anything gdm adds later, so this
# edits only the two keys it owns and leaves every comment, key order and other
# section byte-identical.
#
# WHY IT IS NEEDED AT ALL: THE 2026-09-02 REGRESSION
#
# GDM has no conf.d/ drop-in directory for custom.conf -- /etc/gdm/custom.conf is
# the only file it reads -- so there is nowhere to assert this except in the file
# itself, and nothing owned it. On 2026-09-02 10:13, from inside a `sudo -i`
# shell during the pam_u2f work on /etc/pam.d/gdm-password, AutomaticLoginEnable
# was flipped True -> False so the FIDO prompt could actually be tested. That is
# the correct thing to do while debugging a login prompt, and it was never put
# back.
#
# The failure mode is silent and easy to misread. With autologin off, every boot
# stops at the GDM greeter -- which is GNOME Shell running as the `gdm-greeter`
# user. It looks exactly like "the machine booted into GNOME instead of my
# session", so the instinct is to go hunting in the Hyprland/DMS session, where
# nothing is wrong: /var/lib/AccountsService/users/jo still said
# Session=hyprland-dms the whole time, and picking it at the greeter worked.
#
# ⚠️ THIS FILE DOES NOT DECIDE *WHICH* SESSION AUTOLOGIN STARTS. That comes from
# `Session=` in /var/lib/AccountsService/users/<user>, which GDM rewrites every
# time you log in. Deliberately not forced here: if you pick niri at the greeter,
# autologin should follow you to niri. The task prints that key so it is visible.
#
# Keys are rewritten IN PLACE wherever they already are, including when commented
# out (`#AutomaticLoginEnable=False` is a real state gdm ships), and appended to
# the end of [daemon] when absent. Trailing blank lines are held back so appended
# keys land against the section body instead of after the gap before the next
# [section].
BEGIN { sec = ""; seen_daemon = 0; got_enable = 0; got_user = 0; blanks = 0 }

function emit_blanks() { while (blanks > 0) { print ""; blanks-- } }

function flush_daemon() {
  if (sec == "daemon") {
    if (!got_enable) print "AutomaticLoginEnable=True"
    if (!got_user)   print "AutomaticLogin=" user
    got_enable = 1; got_user = 1
  }
}

/^[[:space:]]*$/ { blanks++; next }

/^[[:space:]]*\[/ {
  flush_daemon(); emit_blanks()
  sec = $0
  sub(/^[[:space:]]*\[/, "", sec); sub(/\][[:space:]]*$/, "", sec)
  if (sec == "daemon") seen_daemon = 1
  print; next
}

# Checked before the bare AutomaticLogin rule below: awk takes the first match,
# and "AutomaticLoginEnable=" must not be consumed as the username key.
sec == "daemon" && /^[[:space:]]*#?[[:space:]]*AutomaticLoginEnable[[:space:]]*=/ {
  emit_blanks()
  if (!got_enable) { print "AutomaticLoginEnable=True"; got_enable = 1 }
  next
}

sec == "daemon" && /^[[:space:]]*#?[[:space:]]*AutomaticLogin[[:space:]]*=/ {
  emit_blanks()
  if (!got_user) { print "AutomaticLogin=" user; got_user = 1 }
  next
}

{ emit_blanks(); print }

END {
  flush_daemon(); emit_blanks()
  if (!seen_daemon) {
    print "[daemon]"
    print "AutomaticLoginEnable=True"
    print "AutomaticLogin=" user
  }
}
