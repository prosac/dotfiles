#!/usr/bin/env bash
# Enables managed *system* (root) services — the sibling to
# enable-session-services.sh, which handles --user units.
# Re-runs automatically when this file changes (i.e. when a service is added).
#
# systemd-oomd: userspace early-OOM killer. Fedora ships it, but it was found
# DISABLED on the laptop — so a runaway process (e.g. an oversized local-LLM
# run under llama.cpp) could exhaust RAM + swap and trip the brutal *kernel*
# OOM-killer, taking the whole desktop (compositor, browser, editors) down with
# it. With oomd enabled, sustained PSI memory-pressure triggers a graceful early
# kill of the greediest cgroup instead. Needs the systemd-oomd-defaults package
# for the ManagedOOMMemoryPressure=kill presets on the user/system slices.
set -euo pipefail

# Idempotent: only invoke sudo when the service actually needs enabling, so a
# later edit to this file (adding another service) won't re-prompt for ones
# already done.
enable_system_service() {
  local svc="$1"
  if systemctl is-enabled --quiet "$svc" 2>/dev/null \
     && systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "  $svc: already enabled+active"
    return 0
  fi
  echo "==> enabling $svc (sudo)"
  sudo systemctl enable --now "$svc"
}

if ! rpm -q systemd-oomd-defaults >/dev/null 2>&1; then
  echo "  WARN: systemd-oomd-defaults not installed — oomd would run without the"
  echo "        ManagedOOM kill presets. Add it in install-packages.sh.tmpl."
fi

enable_system_service systemd-oomd.service
