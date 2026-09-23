#!/usr/bin/env ruby
# frozen_string_literal: true

# term-ident — give a ghostty window a stable visual identity from a seed.
#
# A seed string is hashed to a hue, which drives two coordinated cues so that
# parallel terminals are recognizable at a glance:
#
#   - a subtle, theme-aware BACKGROUND tint   (OSC 11 -> the controlling tty)
#   - a vivid per-window BORDER gradient        (hyprctl dispatch setprop)
#
# Border is the strong, theme-independent cue; the bg tint is the peripheral
# bonus. Degrades to a no-op outside Hyprland / when not running under ghostty.
#
# Both cues are computed against the ACTIVE color scheme, so a dark<->light flip
# invalidates them — an OSC-11 background in particular overrides ghostty's own
# theme background and will not recompute itself. Every applied seed is therefore
# recorded under $XDG_RUNTIME_DIR/term-ident/, and `retint` replays those records
# against the current scheme. toggle-color-scheme calls it on every flip.
#
# Usage:
#   term-ident project [dir]   seed from the git toplevel of dir (default $PWD);
#                              resets to defaults when dir is not in a repo
#   term-ident seed <string>   seed from an arbitrary string
#   term-ident ensure <str>    apply <str> only if not already shown under the
#                              current scheme — the cheap re-assert for a session
#                              with no shell prompt to self-heal from
#   term-ident reset           clear tint + border (back to theme defaults)
#   term-ident retint          re-apply every recorded session for the current
#                              scheme; prunes records of dead sessions
#
# Env:
#   TERM_IDENT_TTY   tty to receive OSC sequences (default /dev/tty)
#   TERM_IDENT_PID   pid to start the ghostty ppid-chain walk from (default self);
#                    lets `retint` resolve a window it is not a descendant of

require "fileutils"
require "json"
require "zlib"
require "open3"

TTY = ENV.fetch("TERM_IDENT_TTY", "/dev/tty")

# Per-session records, keyed by tty. Shares the directory term-ident-claude uses
# for its per-session statusline files; tmpfs, so it clears itself on logout.
STATE_DIR = File.join(ENV.fetch("XDG_RUNTIME_DIR", "/tmp"), "term-ident")

# One-word marker of the active scheme, written by toggle-color-scheme on every
# flip. A cache, never the source of truth — see cached_scheme.
SCHEME_MARKER = File.join(STATE_DIR, "scheme")

# Run a command, returning stripped stdout or nil on any failure.
# capture3 swallows stderr too (e.g. git's "not a git repository" noise).
def run(*args)
  out, _err, status = Open3.capture3(*args)
  status.success? ? out.strip : nil
rescue StandardError
  nil
end

def have?(cmd)
  ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) }
end

def env_pid = Integer(ENV["TERM_IDENT_PID"], exception: false)

# Walk the /proc ppid chain up to the ghostty process that owns us.
#
# `start` (or $TERM_IDENT_PID) overrides the starting point so `retint` can
# resolve a window it is not itself a descendant of. Passing a ghostty pid
# directly is fine — the loop tests the starting pid first.
# Parent of a pid. Split on the LAST ")" — /proc/<pid>/stat embeds the comm in
# parens and a comm may contain spaces, so a plain split misreads it.
def ppid_of(pid)
  File.read("/proc/#{pid}/stat").rpartition(")").last.split[1].to_i
rescue StandardError
  nil
end

# A process's controlling terminal as /dev/pts/N, from /proc/<pid>/stat. tty_nr
# (field 7) is a dev_t: major in bits 8-19, minor in the low 8 bits plus bits
# 20-31. Only UNIX98 pts (major 136) can be a ghostty window.
def ctty(pid)
  tty_nr = File.read("/proc/#{pid}/stat").rpartition(")").last.split[4].to_i
  return nil if tty_nr.zero? || ((tty_nr >> 8) & 0xfff) != 136

  path = "/dev/pts/#{(tty_nr & 0xff) | ((tty_nr >> 12) & 0xfff00)}"
  File.exist?(path) ? path : nil
rescue StandardError
  nil
end

def ghostty_pid(start = nil)
  pid = start || env_pid || Process.pid
  16.times do
    comm = begin
      File.read("/proc/#{pid}/comm").strip
    rescue StandardError
      return nil
    end
    return pid if comm == "ghostty"

    ppid = ppid_of(pid)
    return nil if ppid.nil? || [0, pid].include?(ppid)

    pid = ppid
  end
  nil
end

# Map the owning ghostty process to a Hyprland window address.
#
# Hyprland-only: the per-window border tint goes through `hyprctl setprop`, which
# has no niri equivalent. Under niri this returns nil, so the border step no-ops
# while the OSC-11 background tint (a plain terminal escape) still applies.
def ghostty_address(start = nil)
  return nil unless ENV["XDG_CURRENT_DESKTOP"] == "Hyprland" && have?("hyprctl")

  gpid = ghostty_pid(start) or return nil
  clients = run("hyprctl", "clients", "-j") or return nil
  JSON.parse(clients).find { |c| c["pid"] == gpid }&.fetch("address", nil)
rescue JSON::ParserError
  nil
end

# Opacity for the neutral / no-project state ($HOME etc.) — "ghostly when idle".
IDLE_ALPHA = 0.85
IDLE_ALPHA_INACTIVE = 0.72

# Set Hyprland window props. NB: for color props, -1 restores the global
# default; for opacity, -1 is taken literally and clamps to 0 (invisible!), so
# opacity must always be reset with an explicit 1, never -1.
#
# Prop names are the Hyprland >=0.56 snake_case ones (0.55 and earlier used
# activebordercolor / alpha / alphainactive — no aliases exist either way).
def setprops(addr, props)
  props.each { |prop, val| run("hyprctl", "dispatch", "setprop", "address:#{addr}", prop, val.to_s) }
end

# In a project: colored border + fully opaque (opacity explicitly 1).
def apply_window(active, inactive, pid = nil)
  addr = ghostty_address(pid) or return
  setprops(addr, "active_border_color" => active, "inactive_border_color" => inactive,
                 "opacity" => 1, "opacity_inactive" => 1)
end

# Neutral state: default border + slight transparency.
def reset_window
  addr = ghostty_address or return
  setprops(addr, "active_border_color" => -1, "inactive_border_color" => -1,
                 "opacity" => IDLE_ALPHA, "opacity_inactive" => IDLE_ALPHA_INACTIVE)
end

# Write an escape sequence to the session's terminal. Resolved to a real
# /dev/pts/N first: opening "/dev/tty" fails outright in a process with no
# controlling terminal, which is exactly the case for the Claude
# UserPromptSubmit hook — so the per-session tint used to reach the border (set
# by pid, via hyprctl) but never the background.
def write_tty(seq, tty = nil)
  target = resolve_tty(tty) or return
  File.write(target, seq)
rescue StandardError
  nil
end

def set_bg(hex6, tty = nil) = write_tty("\e]11;##{hex6}\e\\", tty) # OSC 11  — set background
def reset_bg(tty = nil)     = write_tty("\e]111\e\\", tty)         # OSC 111 — reset background

# Real /dev/pts/N our OSC writes should target.
#
# /dev/tty is a magic per-process device and must never be stored: as a state key
# every session collides on one file, and as a replay target it means "whatever
# terminal is reading this record", which for `retint` — spawned from a waybar
# click or a keybind — is no terminal at all, so the write silently goes nowhere.
# Opening it is no help either: a process with no controlling terminal cannot.
#
# So read tty_nr out of /proc instead, walking UP the ppid chain: the Claude
# UserPromptSubmit hook has no controlling terminal of its own (its stdio are
# pipes), but the zsh that started Claude does, and it is the same pts.
def resolve_tty(tty = nil)
  target = tty || TTY
  return target unless target == "/dev/tty" # an explicit target is already real

  pid = Process.pid
  16.times do
    found = ctty(pid)
    return found if found

    ppid = ppid_of(pid)
    return nil if ppid.nil? || [0, pid].include?(ppid)

    pid = ppid
  end
  nil
end

def state_path(tty) = File.join(STATE_DIR, "tty-#{tty.delete_prefix('/dev/').tr('/', '-')}.json")

# Record what this session is showing, so `retint` can replay it after a scheme
# flip. The seed is stored rather than recomputed on purpose: it may have come
# from a Claude prompt (term-ident-claude) rather than the git toplevel, so
# re-deriving it would silently reassign window identities.
def save_state(seed, tty = nil, pid = nil, scheme_name = nil)
  resolved = resolve_tty(tty) or return
  record = { "seed" => seed, "tty" => resolved, "ghostty_pid" => pid || ghostty_pid,
             "scheme" => scheme_name || cached_scheme }
  FileUtils.mkdir_p(STATE_DIR)
  path = state_path(resolved)
  File.write("#{path}.tmp", JSON.generate(record))
  File.rename("#{path}.tmp", path) # atomic — retint may be reading concurrently
rescue StandardError
  nil
end

# Drop this session's record: a reset session needs no replay, since OSC 111 and
# border -1 both fall back to values that are already scheme-correct.
def clear_state
  resolved = resolve_tty or return
  File.unlink(state_path(resolved))
rescue StandardError
  nil
end

# Accents, per scheme. Every tint derives from one of these, so colors always sit
# on-theme; backgrounds are the accent blended into the theme background, borders
# are the accent itself. Six slots, index-aligned across the two schemes.
#
# The two lists are DIFFERENT HUES on purpose — reusing the dark accents on a
# near-white base does not work. Blending any of them into #f9f9f9 crushes them
# toward the same pale wash: the shared palette measured a closest pair of only
# ΔE 4.6 in light (median 9.0) against 7.2/15.5 in dark, i.e. half the separation,
# which is the whole point of the tint. Light therefore widens the wheel past the
# cool run — the "no green/amber" rule was a dark-background constraint (they went
# muddy against #282c34), and on white they are simply pale mint and sand.
#
# Slots 0/2/4 keep their family across a flip (teal, blue, violet).
PALETTE = {
  "dark"  => %w[#4db5bb #46d9ff #51afef #2257a0 #a9a1e1 #c678dd].freeze,
  #            teal     cyan     blue     dark-blue violet   magenta
  "light" => %w[#29758e #146b14 #2531b1 #a15017 #b81fd6 #d61f4c].freeze
  #            teal     green    blue     amber    violet   rose
}.freeze

# Per-scheme theme background + how much accent to blend in for the bg tint.
# `bg` must track ghostty's own theme, since an OSC-11 background replaces it
# rather than tinting it. There is no border_darken knob any more: it existed
# because light reused the dark accents and had to darken them to be visible on
# white; the light accents above are already dark enough to carry a border.
THEME = {
  "dark"  => { bg: "#282c34", frac: 0.28 },
  "light" => { bg: "#f9f9f9", frac: 0.20 }
}.freeze

# The active scheme, "light" or "dark". Read from gsettings because that is what
# toggle-color-scheme (Super+Shift+T) sets, and that is the switch which flips
# ghostty. Unset/auto counts as dark, matching that script's own default.
#
# ⚠️ Do NOT "fix" this to read the xdg-desktop-portal appearance or DMS's own
# isLightMode. There are two independent light/dark switches here: the DMS UI
# switch moves GTK4/libadwaita apps and Chromium but leaves ghostty alone. The
# portal tracks that other one, and it is a convincing trap — at the `default`
# value of color-scheme the portal reports no-preference (0), which libadwaita and
# DMS render as light while ghostty stays dark. A tint blended against the
# portal's answer would be inverted against what the terminal is showing.
def scheme = run("gsettings", "get", "org.gnome.desktop.interface", "color-scheme")
               .to_s.include?("prefer-light") ? "light" : "dark"

# scheme without the gsettings spawn, for hot paths. toggle-color-scheme rewrites
# this marker on every flip; a missing or junk marker just costs the real lookup.
def cached_scheme
  val = File.read(SCHEME_MARKER).strip
  THEME.key?(val) ? val : scheme
rescue StandardError
  scheme
end

def accent_for(seed, scheme_name = nil)
  palette = PALETTE[scheme_name || cached_scheme]
  palette[Zlib.crc32(seed) % palette.size]
end

def rgb(hex6) = hex6.delete("#").scan(/../).map { |c| c.to_i(16) }
def hex(rgb) = format("%02x%02x%02x", *rgb)
# round half-up to stay bit-identical to term-ident (Python)
def mix(a, b, f) = a.zip(b).map { |x, y| (x * (1 - f) + y * f + 0.5).to_i }

def apply_seed(seed, tty = nil, pid = nil)
  name = scheme
  t = THEME[name]
  border = accent = rgb(accent_for(seed, name))
  theme_bg = rgb(t[:bg])
  black = [0, 0, 0]

  bg = mix(theme_bg, accent, t[:frac])                 # accent blended into theme bg
  active   = "rgba(#{hex(border)}ee) rgba(#{hex(mix(border, black, 0.30))}ee) 45deg"
  inactive = "rgba(#{hex(mix(border, theme_bg, 0.45))}aa)"

  set_bg(hex(bg), tty)
  apply_window(active, inactive, pid)
  save_state(seed, tty, pid, name)
end

# Apply the seed only if this session is not already showing it, unchanged, under
# the current scheme.
#
# The self-heal path for Claude sessions. A shell re-runs `project` from its
# precmd hook on every prompt, so it repairs itself the moment anything moves; a
# Claude session prints no shell prompt for the whole time it runs, so a flip
# partway through would otherwise leave it wearing the old scheme's tint — which
# on a flip to light is a dark background under Atom One Light's dark ink.
def ensure_seed(seed)
  resolved = resolve_tty
  name = scheme
  if resolved
    record = begin
      JSON.parse(File.read(state_path(resolved)))
    rescue StandardError
      nil
    end
    return if record && record["seed"] == seed && record["scheme"] == name
  end
  apply_seed(seed)
end

def reset_all
  reset_bg
  reset_window
  clear_state
end

# Re-apply every recorded session against the current scheme. Called by
# toggle-color-scheme after it flips gsettings. Records whose tty or ghostty
# process is gone are pruned as we go.
def retint
  Dir.children(STATE_DIR).sort.each do |name|
    next unless name.start_with?("tty-") && name.end_with?(".json")

    path = File.join(STATE_DIR, name)
    record = begin
      JSON.parse(File.read(path))
    rescue StandardError
      next
    end
    seed, tty, pid = record.values_at("seed", "tty", "ghostty_pid")
    # A record must name a real pts. Older builds stored the literal "/dev/tty",
    # which every session resolved to — so they all collided on one file, and
    # replaying it wrote to whatever terminal `retint` itself had, i.e. none.
    alive = seed && tty && tty.start_with?("/dev/pts/") && File.exist?(tty) &&
            (!pid || File.exist?("/proc/#{pid}"))
    if alive
      apply_seed(seed, tty, pid)
    else
      File.unlink(path) rescue nil # rubocop:disable Style/RescueModifier
    end
  end
rescue SystemCallError
  nil
end

case ARGV[0] || "project"
when "reset"
  reset_all
when "seed"
  ARGV[1].to_s.empty? ? reset_all : apply_seed(ARGV[1])
when "ensure"
  ensure_seed(ARGV[1]) unless ARGV[1].to_s.empty?
when "retint"
  retint
when "project", ""
  dir = ARGV[1] || Dir.pwd
  top = run("git", "-C", dir, "rev-parse", "--show-toplevel")
  top ? apply_seed(top) : reset_all
else
  warn "usage: term-ident {project [dir]|seed <string>|ensure <string>|reset|retint}"
  exit 2
end
