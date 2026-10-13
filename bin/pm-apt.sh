#!/bin/bash
# Backend: Debian/Ubuntu (apt). Sourced by update-all.sh — not run directly.
# Provides: pm_name, pm_check, pm_update. Uses $SUDO, $TMP, log(), UPDATED.
# Covers every configured apt repo (including PPAs) via apt list.
PM_PROBE="/usr/bin/apt-get --version"
pm_name() { echo "apt"; }

pm_check() {
  ZYPPER_N=0; PACKMAN_N=0; SYS_HIT=0
  LIST_OUT=$(apt list --upgradable 2>/dev/null | grep -c / || true)
  LIST_OUT=${LIST_OUT:-0}
  if [ "$LIST_OUT" -eq 0 ]; then
    log "check: apt: nothing to do."
  else
    ZYPPER_N=$LIST_OUT
    UPDATED=1
    if apt list --upgradable 2>/dev/null | grep -qiE "linux-image|systemd|dbus|libc6|udev|initramfs"; then SYS_HIT=1; fi
    log "check: apt: ${ZYPPER_N} package(s) available (all repos incl. PPAs)."
  fi
  EXTRA_N=0
  return 0
}

pm_update() {
  echo "--- apt update ---"
  if $SUDO /usr/bin/apt-get update >"$TMP" 2>&1; then
    cat "$TMP"
    log "apt update: ok."
  else
    cat "$TMP"; log "apt update: FAILED"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    return 1
  fi
  echo "--- apt upgrade ---"
  if $SUDO /usr/bin/apt-get upgrade -y >"$TMP" 2>&1; then
    cat "$TMP"
    if grep -qi "0 upgraded, 0 newly installed" "$TMP"; then
      log "apt upgrade: nothing to do."
    else
      UPDATED=1
      if grep -qiE "linux-image|systemd|dbus|libc6|udev|initramfs" "$TMP"; then IMPORTANT=1; fi
      grep -iE "upgraded|newly installed" "$TMP" >> "$LOG" || true
      grep -iE "^.*(error|failed|warning).*$" "$TMP" >> "$LOG" || true
    fi
  else
    cat "$TMP"; log "apt upgrade: FAILED"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    return 1
  fi
  return 0
}
