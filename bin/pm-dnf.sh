#!/bin/bash
# Backend: Fedora/RHEL (dnf). Sourced by update-all.sh — not run directly.
# Provides: pm_name, pm_check, pm_update. Uses $SUDO, $TMP, log(), UPDATED.
# Note: `dnf check-update` exits 100 when updates exist (not a failure).
PM_PROBE="/usr/bin/dnf --version"
pm_name() { echo "dnf"; }

pm_check() {
  ZYPPER_N=0; PACKMAN_N=0; SYS_HIT=0
  sudo -n /usr/bin/dnf check-update -q >"$TMP" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    log "check: dnf: nothing to do."
  elif [ "$rc" -eq 100 ]; then
    ZYPPER_N=$(grep -cE "^[[:alnum:].+_-]+[[:space:]]" "$TMP" || true)
    ZYPPER_N=${ZYPPER_N:-1}
    UPDATED=1
    if grep -qiE "kernel-core|kernel-modules|systemd|dbus|glibc|udev|dracut" "$TMP"; then SYS_HIT=1; fi
    log "check: dnf: ${ZYPPER_N} package(s) available."
    PACKMAN_N=$(grep -ci "rpmfusion" "$TMP" || true)
    PACKMAN_N=${PACKMAN_N:-0}
    log "check: rpmfusion: ${PACKMAN_N} package(s) available."
  else
    cat "$TMP"; log "check: dnf query FAILED"; return 1
  fi
  EXTRA_N=$PACKMAN_N
  return 0
}

pm_update() {
  echo "--- dnf upgrade ---"
  if $SUDO /usr/bin/dnf upgrade --refresh -y >"$TMP" 2>&1; then
    cat "$TMP"
    if ! grep -qi "Nothing to do" "$TMP"; then
      UPDATED=1
      if grep -qiE "kernel-core|kernel-modules|systemd|dbus|glibc|udev|dracut" "$TMP"; then IMPORTANT=1; fi
      grep -iE "Upgraded|Installed|Nothing to do" "$TMP" >> "$LOG" || true
      grep -iE "^.*(error|failed|warning).*$" "$TMP" >> "$LOG" || true
    else
      log "dnf upgrade: nothing to do."
    fi
  else
    cat "$TMP"; log "dnf upgrade: FAILED"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    return 1
  fi
  return 0
}
