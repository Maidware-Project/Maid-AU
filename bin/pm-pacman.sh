#!/bin/bash
# Backend: Arch Linux (pacman). Sourced by update-all.sh — not run directly.
# Provides: pm_name, pm_check, pm_update. Uses $SUDO, $TMP, log(), UPDATED.
# AUR helper (yay/paru) used read-only for counting when present.
PM_PROBE="/usr/bin/pacman --version"
pm_name() { echo "pacman"; }

_aur_helper() {
  for h in yay paru; do
    if command -v "$h" >/dev/null 2>&1; then echo "$h"; return 0; fi
  done
  return 1
}

pm_check() {
  ZYPPER_N=0; PACKMAN_N=0; SYS_HIT=0
  if command -v checkupdates >/dev/null 2>&1; then
    LIST_OUT=$(checkupdates 2>/dev/null || true)
  else
    LIST_OUT=$(pacman -Qu 2>/dev/null || true)
  fi
  if [ -z "$LIST_OUT" ]; then
    log "check: pacman: nothing to do."
  else
    ZYPPER_N=$(echo "$LIST_OUT" | grep -c . || true)
    ZYPPER_N=${ZYPPER_N:-1}
    UPDATED=1
    if echo "$LIST_OUT" | grep -qiE "^linux |^linux-lts |systemd|dbus|glibc|udev|mkinitcpio"; then SYS_HIT=1; fi
    log "check: pacman: ${ZYPPER_N} package(s) available."
  fi
  AURH=$(_aur_helper || true)
  if [ -n "$AURH" ]; then
    AUR_OUT=$("$AURH" -Qu 2>/dev/null || true)
    PACKMAN_N=$(echo "$AUR_OUT" | grep -c . || true)
    PACKMAN_N=${PACKMAN_N:-0}
    log "check: AUR ($AURH): ${PACKMAN_N} package(s) available."
  else
    log "check: AUR: no helper (yay/paru) installed, skipped."
  fi
  EXTRA_N=$PACKMAN_N
  return 0
}

pm_update() {
  echo "--- pacman -Syu ---"
  SNAP_PRE_ID=$(snap_pre "pacman")
  if $SUDO /usr/bin/pacman -Syu --noconfirm >"$TMP" 2>&1; then
    cat "$TMP"
    if grep -qi "there is nothing to do" "$TMP"; then
      log "pacman: nothing to do."
    else
      UPDATED=1
      if grep -qiE "upgraded linux |upgraded linux-lts |upgraded systemd|upgraded dbus|upgraded glibc|upgraded udev|upgraded mkinitcpio" "$TMP"; then IMPORTANT=1; fi
      grep -iE "upgraded|installed|there is nothing to do" "$TMP" >> "$LOG" || true
      grep -iE "^.*(error|failed|warning).*$" "$TMP" >> "$LOG" || true
    fi
  else
    cat "$TMP"; log "pacman: FAILED"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    return 1
  fi
  AURH=$(_aur_helper || true)
  if [ -n "$AURH" ]; then
    echo "--- AUR ($AURH -Sua) ---"
    if "$AURH" -Sua --noconfirm >"$TMP" 2>&1; then
      cat "$TMP"
      log "AUR update attempted (see above)."
    else
      cat "$TMP"; log "AUR update: FAILED (non-fatal)"
    fi
  fi
  snap_post "pacman"
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
