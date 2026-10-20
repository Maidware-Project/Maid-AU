#!/usr/bin/env bash
# Backend: Fedora/RHEL (dnf). Sourced by update-all.sh - not run directly.
# Provides: pm_name, pm_check, pm_update. Uses $SUDO, $TMP, log(), UPDATED.
# Note: `dnf check-update` exits 100 when updates exist (not a failure).
# shellcheck disable=SC2034  # cross-file state: read by update-all.sh after sourcing
PM_PROBE="dnf --version"
pm_name() { echo "dnf"; }

pm_check() {
  ZYPPER_N=0; PACKMAN_N=0; SYS_HIT=0
  # shellcheck disable=SC2024  # $TMP is user-owned: the redirect stays with the user
  $SUDO dnf check-update -q >"$TMP" 2>&1; rc=$?
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
  SNAP_PRE_ID=$(snap_pre "dnf")
  if [ -z "$SNAP_PRE_ID" ]; then
    if [ "$REQUIRE_SNAP" = "1" ]; then
      echo "ABORT: --require-snapshot and pre-snapshot failed."
      log "strict abort: no pre-snapshot."
      exit 2
    fi
    say "safety: pre-update snapshot FAILED - continuing without rollback (--require-snapshot aborts instead)."
  fi
  if $SUDO dnf upgrade --refresh -y >"$TMP" 2>&1; then
    cat "$TMP"
    if ! grep -qi "Nothing to do" "$TMP"; then
      UPDATED=1
      if grep -qiE "kernel-core|kernel-modules|systemd|dbus|glibc|udev|dracut" "$TMP"; then IMPORTANT=1; fi
      if command -v needs-restarting >/dev/null 2>&1; then
        if needs-restarting -r >/dev/null 2>&1; then :; else IMPORTANT=1; log "reboot hint: needs-restarting wants a reboot."; fi
      fi
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
  snap_post "dnf"
  SNAP_POST_ID=$(snap_last)
  if [ -n "$SNAP_PRE_ID" ] && [ -n "$SNAP_POST_ID" ] && [ "$SNAP_PRE_ID" != "timeshift" ]; then
    SNAP_INFO="snapshots #$SNAP_PRE_ID -> #$SNAP_POST_ID (rollback: sudo snapper -c root rollback <pre#>)"
    log "safety: $SNAP_INFO"
  elif [ "$SNAP_PRE_ID" = "timeshift" ]; then
    SNAP_INFO="timeshift snapshot taken (restore: timeshift --restore)"
    log "safety: $SNAP_INFO"
  fi
  return 0
}
