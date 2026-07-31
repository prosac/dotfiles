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
def ghostty_pid(start = nil)
  pid = start || env_pid || Process.pid
  16.times do
    comm = File.read("/proc/#{pid}/comm").strip
    ppid = File.read("/proc/#{pid}/stat").split[3].to_i
    return pid if comm == "ghostty"
    return nil if [0, pid].include?(ppid)

    pid = ppid
  rescue StandardError
    return nil
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
# default; for alpha, -1 is taken literally and clamps to 0 (invisible!), so
# opacity must always be reset with an explicit 1, never -1.
def setprops(addr, props)
  props.each { |prop, val| run("hyprctl", "dispatch", "setprop", "address:#{addr}", prop, val.to_s) }
end

# In a project: colored border + fully opaque (alpha explicitly 1).
def apply_window(active, inactive, pid = nil)
  addr = ghostty_address(pid) or return
  setprops(addr, "activebordercolor" => active, "inactivebordercolor" => inactive,
                 "alpha" => 1, "alphainactive" => 1)
end

# Neutral state: default border + slight transparency.
def reset_window
  addr = ghostty_address or return
  setprops(addr, "activebordercolor" => -1, "inactivebordercolor" => -1,
                 "alpha" => IDLE_ALPHA, "alphainactive" => IDLE_ALPHA_INACTIVE)
end

def write_tty(seq, tty = nil)
  File.write(tty || TTY, seq)
rescue StandardError
  nil
end

def set_bg(hex6, tty = nil) = write_tty("\e]11;##{hex6}\e\\", tty) # OSC 11  — set background
def reset_bg                = write_tty("\e]111\e\\")             # OSC 111 — reset background

# Real device path of our OSC target. /dev/tty is a magic per-process device, so
# it must be resolved to the actual /dev/pts/N before it can key state.
def resolve_tty(tty = nil)
  target = tty || TTY
  fd = IO.sysopen(target, File::RDONLY | File::NOCTTY)
  io = IO.new(fd)
  begin
    File.readlink("/proc/self/fd/#{fd}")
  rescue StandardError
    target == "/dev/tty" ? nil : target
  ensure
    io.close
  end
rescue StandardError
  nil
end

def state_path(tty) = File.join(STATE_DIR, "tty-#{tty.delete_prefix('/dev/').tr('/', '-')}.json")

# Record what this session is showing, so `retint` can replay it after a scheme
# flip. The seed is stored rather than recomputed on purpose: it may have come
# from a Claude prompt (term-ident-claude) rather than the git toplevel, so
# re-deriving it would silently reassign window identities.
def save_state(seed, tty = nil, pid = nil)
  resolved = resolve_tty(tty) or return
  record = { "seed" => seed, "tty" => resolved, "ghostty_pid" => pid || ghostty_pid }
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

# Cool accents from the theme palette (Doom One + doom-emacs extended). Every
# tint derives from one of these, so colors always sit on-theme. Edit the list
# to retune; backgrounds are these accents blended into the theme background,
# borders are the accents themselves.
PALETTE = %w[#4db5bb #46d9ff #51afef #2257a0 #a9a1e1 #c678dd].freeze
#            teal     cyan     blue     dark-blue violet   magenta

# Per-scheme theme background + how much accent to blend in for the bg tint.
THEME = {
  "dark"  => { bg: "#282c34", frac: 0.28, border_darken: 0.00 },
  "light" => { bg: "#f9f9f9", frac: 0.20, border_darken: 0.30 }
}.freeze

def scheme_light? = run("gsettings", "get", "org.gnome.desktop.interface", "color-scheme")
                      .to_s.include?("prefer-light") # default to dark when unset/auto

def rgb(hex6) = hex6.delete("#").scan(/../).map { |c| c.to_i(16) }
def hex(rgb) = format("%02x%02x%02x", *rgb)
# round half-up to stay bit-identical to term-ident (Python)
def mix(a, b, f) = a.zip(b).map { |x, y| (x * (1 - f) + y * f + 0.5).to_i }

def apply_seed(seed, tty = nil, pid = nil)
  t = THEME[scheme_light? ? "light" : "dark"]
  accent = rgb(PALETTE[Zlib.crc32(seed) % PALETTE.size])
  theme_bg = rgb(t[:bg])
  black = [0, 0, 0]

  bg     = mix(theme_bg, accent, t[:frac])             # accent blended into theme bg
  border = mix(accent, black, t[:border_darken])       # darkened on light for contrast
  active   = "rgba(#{hex(border)}ee) rgba(#{hex(mix(border, black, 0.30))}ee) 45deg"
  inactive = "rgba(#{hex(mix(border, theme_bg, 0.45))}aa)"

  set_bg(hex(bg), tty)
  apply_window(active, inactive, pid)
  save_state(seed, tty, pid)
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
    alive = seed && tty && File.exist?(tty) && (!pid || File.exist?("/proc/#{pid}"))
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
when "retint"
  retint
when "project", ""
  dir = ARGV[1] || Dir.pwd
  top = run("git", "-C", dir, "rev-parse", "--show-toplevel")
  top ? apply_seed(top) : reset_all
else
  warn "usage: term-ident {project [dir]|seed <string>|reset|retint}"
  exit 2
end
