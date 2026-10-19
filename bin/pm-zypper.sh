#!/usr/bin/env bash
# Backend: openSUSE (zypper). Sourced by update-all.sh - not run directly.
# Provides: pm_name, pm_check, pm_update. Uses $SUDO, $TMP, log(), UPDATED.
# shellcheck disable=SC2034  # cross-file state: read by update-all.sh after sourcing
PM_PROBE="zypper --version"
pm_name() { echo "zypper"; }

pm_check() {
  ZYPPER_N=0; PACKMAN_N=0; SYS_HIT=0
  # shellcheck disable=SC2024  # $TMP is user-owned: the redirect stays with the user
  if sudo -n zypper --non-interactive dist-upgrade --dry-run --no-confirm >"$TMP" 2>&1; then
    if grep -qi "Nothing to do" "$TMP"; then
      log "check: zypper: nothing to do."
    else
      ZYPPER_N=$(grep -oE "[0-9]+ packages are going to be upgraded" "$TMP" | grep -oE "^[0-9]+" | head -n1)
      ZYPPER_N=${ZYPPER_N:-1}
      UPDATED=1
      if grep -qiE "kernel-default|kernel-firmware|systemd|dbus-1|glibc|udev|dracut" "$TMP"; then SYS_HIT=1; fi
      log "check: zypper: ${ZYPPER_N} package(s) available."
    fi
  else
    cat "$TMP"; log "check: zypper dry-run FAILED"; return 1
  fi

  # shellcheck disable=SC2024  # $TMP is user-owned: the redirect stays with the user
  if sudo -n zypper --non-interactive list-updates -r packman >"$TMP" 2>&1; then
    if grep -qi "No updates found" "$TMP"; then
      log "check: packman: none."
    else
      PACKMAN_N=$(grep -c "^v " "$TMP" || true)
      PACKMAN_N=${PACKMAN_N:-1}
      log "check: packman: ${PACKMAN_N} package(s) available."
    fi
  else
    cat "$TMP"; log "check: packman query FAILED"; return 1
  fi
  EXTRA_N=$PACKMAN_N
  return 0
}

pm_update() {
  echo "--- zypper refresh ---"
  if $SUDO zypper --non-interactive refresh >"$TMP" 2>&1; then
    cat "$TMP"
    if grep -qiE "error|failed|warning" "$TMP"; then
      grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    else
      log "zypper refresh: ok."
    fi
  else
    cat "$TMP"; log "zypper refresh: FAILED"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    return 1
  fi

  echo "--- bootable snapshots ---"
  if ! rpm -q grub2-snapper-plugin >/dev/null 2>&1; then
    echo "installing grub2-snapper-plugin (snapshot boot entries)..."
    if $SUDO zypper --non-interactive install --no-confirm --no-refresh -y grub2-snapper-plugin >"$TMP" 2>&1; then
      log "grub2-snapper-plugin: installed."
    else
      log "grub2-snapper-plugin: skipped/failed (non-fatal, snapshots still taken)."
    fi
  fi
  SNAP_PRE_ID=$(snap_last)
  if [ -z "$SNAP_PRE_ID" ]; then
    if [ "$REQUIRE_SNAP" = "1" ]; then
      echo "ABORT: --require-snapshot and no snapshot before the upgrade."
      log "strict abort: no pre-update snapshot (zypper)."
      exit 2
    fi
    say "safety: no snapshot before the upgrade - continuing without rollback (--require-snapshot aborts instead)."
  fi
  echo "--- zypper dup (rpm packages) ---"
  # NOTE: --allow-vendor-change is required on Tumbleweed, not a shortcut:
  # without it dup stalls on vendor flips (Packman codec switches, repo
  # moves). Scoped to this explicit, user-invoked full upgrade - the
  # scripts never auto-update in the background.
  if $SUDO zypper --non-interactive dist-upgrade --no-confirm --allow-vendor-change >"$TMP" 2>&1; then
    cat "$TMP"
    if ! grep -qi "Nothing to do" "$TMP"; then
      UPDATED=1
      if grep -qiE "kernel-default|kernel-firmware|systemd|dbus-1|glibc|udev|dracut" "$TMP"; then IMPORTANT=1; fi
      grep -E "packages are going to be|package is going to|change vendor|Nothing to do" "$TMP" >> "$LOG" || true
      grep -iE "^.*(error|failed|warning).*$" "$TMP" >> "$LOG" || true
    else
      log "zypper dup: nothing to do."
    fi
  else
    cat "$TMP"; log "zypper dup: FAILED"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    return 1
  fi
  SNAP_POST_ID=$(snap_last)
  if [ -n "$SNAP_PRE_ID" ] && [ -n "$SNAP_POST_ID" ]; then
    SNAP_INFO="snapshots #$SNAP_PRE_ID -> #$SNAP_POST_ID (rollback: boot one from GRUB, or sudo snapper -c root rollback <pre#>)"
    log "safety: $SNAP_INFO"
  fi
  return 0
}
