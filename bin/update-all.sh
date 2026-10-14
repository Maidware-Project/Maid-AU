#!/usr/bin/env bash
# One-button system updater: flatpak + native packages + firmware.
# Backends in pm-*.sh (zypper/dnf/pacman/apt), auto-detected, override with UPDATE_PM.
LOG="$HOME/.local/share/update-all.log"
LASTFILE="$HOME/.local/share/update-all.last"
STALE_DAYS=3
mkdir -p "$(dirname "$LOG")"

# flags: --require-snapshot aborts the system upgrade unless snapshots work.
# May appear anywhere in argv; the rest keeps positional meaning.
REQUIRE_SNAP=0
POSARGS=""
for _a in "$@"; do
  if [ "$_a" = "--require-snapshot" ]; then REQUIRE_SNAP=1
  else POSARGS="$POSARGS$_a "; fi
done
# shellcheck disable=SC2086
set -- $POSARGS

notify() {
  local summary="$1"; local body="${2:-}"; local urgency="${3:-normal}"; local icon="${4:-software-update-available}"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "System Updater" -u "$urgency" -i "$icon" "$summary" "$body"
  else
    kdialog --passivepopup "$summary $body" 5
  fi
}

last_info() {
  if [ -f "$LASTFILE" ]; then
    local last_epoch now age age_h age_d last_date
    last_epoch=$(head -n1 "$LASTFILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - last_epoch))
    age_h=$((age / 3600))
    age_d=$((age / 86400))
    last_date=$(date -d "@$last_epoch" "+%Y-%m-%d %H:%M")
    if [ "$age_d" -ge 1 ]; then
      echo "Last successful update: $last_date (${age_d}d ago)"
    elif [ "$age_h" -ge 1 ]; then
      echo "Last successful update: $last_date (${age_h}h ago)"
    else
      echo "Last successful update: $last_date (<1h ago)"
    fi
  else
    echo "No record of previous successful update."
  fi
}

# Check-only mode: report when the last successful update ran.
if [ "${1:-}" = "--last" ]; then
  INFO=$(last_info)
  echo "$INFO"
  notify "Last update check" "$INFO" normal software-update-available
  if [ -t 1 ]; then
    echo ""; read -n1 -s -r -p "Press any key to close..."; echo ""
  fi
  exit 0
fi

# Single-press guard: exit if already running
mkdir -p "$HOME/.cache"
exec 200>"$HOME/.cache/update-all.lock"
if ! flock -n 200; then
  notify "Update already running" "An update is already in progress." low dialog-information
  echo "=== $(date) === already running, exiting ===" >> "$LOG"
  exit 1
fi

set -o pipefail
FAILED=0
UPDATED=0
IMPORTANT=0
PARTIAL=0
SNAP_INFO=""
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

log() { echo "$*" >> "$LOG"; }
trim_log() {
  local max_lines=1000
  if [ -f "$LOG" ]; then
    tail -n "$max_lines" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}
say() { echo "$*"; log "$*"; }

# ---- safety net: snapshots around upgrades (rollback beats fear) ----
snap_last_q() {
  # check mode only: never prompts, silent skip without root
  sudo -n snapper -c root list --columns number 2>/dev/null | tail -n 1 || true
}
snap_last() { $SUDO snapper -c root list --columns number 2>/dev/null | tail -n 1 || true; }
snap_pre() {
  # $1 label -> snapshot id or "" (snapper preferred, btrfs timeshift fallback)
  if $SUDO snapper -c root list >/dev/null 2>&1; then
    $SUDO snapper -c root create --description "maidau-pre: $1" --print-number 2>/dev/null || true
  elif command -v timeshift >/dev/null 2>&1 && [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = "btrfs" ]; then
    $SUDO timeshift --create --comments "maidau-pre: $1" >/dev/null 2>&1 && echo "timeshift" || true
  fi
}
snap_post() {
  # $1 label
  if $SUDO snapper -c root list >/dev/null 2>&1; then
    $SUDO snapper -c root create --description "maidau-post: $1" >/dev/null 2>&1 || true
  elif command -v timeshift >/dev/null 2>&1 && [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = "btrfs" ]; then
    $SUDO timeshift --create --comments "maidau-post: $1" >/dev/null 2>&1 || true
  fi
}
snap_has_tools() {
  # strict-mode preflight: snapshot tooling exists (no snapshot taken)
  $SUDO snapper -c root list >/dev/null 2>&1 && return 0
  command -v timeshift >/dev/null 2>&1 && [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = "btrfs" ] && return 0
  return 1
}

# ---- backend select ----
detect_pm() {
  if [ -n "${UPDATE_PM:-}" ]; then echo "$UPDATE_PM"; return; fi
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
      *arch*) echo pacman; return ;;
      *debian*|*ubuntu*) echo apt; return ;;
      *fedora*|*rhel*|*centos*) echo dnf; return ;;
      *suse*|*opensuse*) echo zypper; return ;;
    esac
  fi
  for c in pacman apt-get dnf zypper; do
    command -v "$c" >/dev/null 2>&1 && { case "$c" in
      pacman) echo pacman; return ;;
      apt-get) echo apt; return ;;
      dnf) echo dnf; return ;;
      zypper) echo zypper; return ;; esac; }
  done
  echo none
}
PM=$(detect_pm)
BACKEND_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$BACKEND_DIR/pm-${PM}.sh"
if [ ! -f "$BACKEND" ]; then
  say "ERROR: no backend for package manager '$PM'."
  notify "Updater unsupported" "No backend for '$PM'." critical dialog-error
  exit 1
fi
# shellcheck disable=SC1090
. "$BACKEND"
PM_LABEL=$(pm_name)

# ---- sudo: passwordless preferred, interactive fallback ----
if sudo -n true >/dev/null 2>&1; then
  SUDO="sudo -n"
elif [ -n "${PM_PROBE:-}" ] && sudo -n $PM_PROBE >/dev/null 2>&1; then
  # NOPASSWD covers just the package manager (e.g. zypper-only rule)
  SUDO="sudo -n"
else
  SUDO="sudo"
  say "NOTE: no passwordless sudo - you may be asked for your password."
fi
export SUDO

controllers_hook() {
  # mode: $1 = check|update
  # Bazzite KMP stack is opt-in (UPDATE_CONTROLLERS=1), announced up front
  # in update mode so it never surprises anyone mid-run.
  if [ "${UPDATE_CONTROLLERS:-0}" != "1" ]; then
    log "controllers: skipped (opt-in: UPDATE_CONTROLLERS=1 update-all.sh)."
    [ "$1" = "check" ] && echo 0
    return 0
  fi
  if [ "$PM" = "zypper" ] && [ -x "$HOME/.local/bin/setup-controllers.sh" ]; then
    if [ "$1" = "update" ]; then
      echo "--- controllers (auto-update) ---"
      if "$HOME/.local/bin/setup-controllers.sh" --update >"$TMP" 2>&1; then
        cat "$TMP"
        if grep -qiE "Installing|Updating|enabling|adding .* to" "$TMP"; then
          UPDATED=1
          grep -iE "Installing|Updating|enabling|adding|WARNING|FAILED" "$TMP" >> "$LOG" || true
        else
          log "controllers: up to date."
        fi
      else
        cat "$TMP"; FAILED=1
        log "controllers: FAILED"
        grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
      fi
      if [ -x "$HOME/.local/bin/check-controllers.sh" ]; then
        if "$HOME/.local/bin/check-controllers.sh" --short >"$TMP" 2>&1; then
          log "controllers check: healthy."
        else
          cat "$TMP"
          log "controllers check: issues found (see above)."
          grep -E "FAIL|WARN" "$TMP" >> "$LOG" || true
        fi
      fi
    else
      CTRL_N=0
      if sudo -n zypper --non-interactive list-updates >"$TMP" 2>&1; then
        if grep -qi "No updates found" "$TMP"; then
          log "check: controllers: none."
        else
          CTRL_N=$(grep -cE "xone|xpadneo|joycond|inputplumber|hid-tmff2" "$TMP" || true)
          CTRL_N=${CTRL_N:-0}
          [ "$CTRL_N" -gt 0 ] && UPDATED=1
          log "check: controllers: ${CTRL_N} package(s) available."
        fi
      else
        if grep -qi "No updates found" "$TMP"; then
          log "check: controllers: none."
        else
          cat "$TMP"; return 1
        fi
      fi
      for _cp in xone-kmp-default xpadneo-kmp-default joycond inputplumber hid-tmff2-kmp-default; do
        if ! rpm -q "$_cp" >/dev/null 2>&1; then CTRL_N=$((CTRL_N+1)); UPDATED=1; log "check: controllers: $_cp missing."; break; fi
      done
      echo "$CTRL_N"
    fi
  else
    log "controllers: backend '$PM' has no controller hook (see README)."
    [ "$1" = "check" ] && echo 0
  fi
}

flatpak_check() {
  if flatpak remote-ls --updates --app >"$TMP" 2>&1; then
    FLAT_N=$(grep -c . "$TMP" || true)
    if [ "$FLAT_N" -gt 0 ]; then
      log "check: flatpak: ${FLAT_N} app(s) available."
    else
      log "check: flatpak: none."
    fi
  else
    cat "$TMP" >&2; return 1
  fi
  echo "$FLAT_N"
}

flatpak_update() {
  echo "--- flatpak (user + system) ---"
  if flatpak update -y >"$TMP" 2>&1; then
    cat "$TMP"
    if ! grep -qi "Nothing to update" "$TMP"; then
      UPDATED=1
      grep -viE "Looking for updates|^$" "$TMP" >> "$LOG" || true
    else
      log "flatpak: nothing to update."
    fi
  else
    cat "$TMP"; FAILED=1
    log "flatpak: FAILED"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
  fi
}

appimage_dirs() {
  for d in "$HOME/AppImages" "$HOME/Applications" /opt/appimages; do
    [ -d "$d" ] && echo "$d"
  done
}

appimage_files() {
  local d
  for d in $(appimage_dirs); do
    find "$d" -maxdepth 2 -type f -name "*.AppImage" 2>/dev/null
  done
}

appimage_check() {
  # echo count of managed AppImages (embedded info + configured links)
  local n=0 f
  if command -v appimageupdatetool >/dev/null 2>&1; then
    for f in $(appimage_files); do
      if echo n | appimageupdatetool "$f" 2>&1 | grep -qiE "update (available|found)|new version|up to date|already"; then
        n=$((n+1))
      fi
    done
  fi
  if [ -f "$HOME/.config/maidau-appimages.conf" ]; then
    n=$((n + $(grep -vcE '^\s*(#|$)' "$HOME/.config/maidau-appimages.conf" || true)))
  fi
  log "check: appimages: ${n} managed."
  echo "$n"
}

appimage_update() {
  echo "--- appimages ---"
  local f out changed=0
  if command -v appimageupdatetool >/dev/null 2>&1; then
    for f in $(appimage_files); do
      out=$(yes 2>/dev/null | appimageupdatetool "$f" 2>&1 || true)
      if echo "$out" | grep -qiE "up to date|already|no update information"; then
        log "appimage: $(basename "$f"): nothing to do."
      elif echo "$out" | grep -qiE "updat|success"; then
        log "appimage: $(basename "$f"): updated."
        UPDATED=1; changed=1
      else
        log "appimage: $(basename "$f"): unclear result (see terminal)."
        echo "$out" | tail -n 5
        PARTIAL=1
      fi
    done
  else
    log "appimage: no appimageupdatetool (skipping embedded updates)."
  fi
  appimage_links
  [ "$changed" = "1" ] && UPDATED=1
  return 0
}

appimage_links() {
  # user-provided direct links: Name|URL per line. downloads only when the
  # remote changed (ETag/Last-Modified cache), backs up before replacing.
  local conf="$HOME/.config/maidau-appimages.conf"
  local state="$HOME/.local/share/maidau-appimages.state"
  [ -f "$conf" ] || return 0
  command -v curl >/dev/null 2>&1 || { log "appimage links: no curl, skipped."; return 0; }
  mkdir -p "$(dirname "$state")"; touch "$state" 2>/dev/null || true
  local name url dest etag lastmod cached tmp dl
  while IFS='|' read -r name url _rest; do
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$url" ] || continue
    dest=$(appimage_files | grep -m1 "/$(basename "$name" .AppImage)" || true)
    if [ -z "$dest" ]; then
      dest="$HOME/AppImages/$(basename "$name")"
      [ "${dest%.AppImage}" = "$dest" ] && dest="$dest.AppImage"
    fi
    etag=$(curl -sI "$url" 2>/dev/null | grep -i '^etag:' | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]: *//;s/ *$//')
    lastmod=$(curl -sI "$url" 2>/dev/null | grep -i '^last-modified:' | tr -d '\r' | sed 's/^[Ll]ast-[Mm]odified: *//;s/ *$//')
    cached=$(grep -m1 "^$(basename "$dest")|" "$state" 2>/dev/null || true)
    if [ -n "$etag$lastmod" ] && [ "$cached" = "$(basename "$dest")|$etag|$lastmod" ]; then
      log "appimage link: $(basename "$dest"): unchanged, skipped."
      continue
    fi
    tmp=$(mktemp /tmp/maidau-appimg.XXXXXX) || continue
    if curl -sL --max-time 300 -o "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
      mkdir -p "$(dirname "$dest")"
      if [ -e "$dest" ]; then
        cp -a "$dest" "${dest}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
      fi
      mv "$tmp" "$dest" && chmod +x "$dest"
      log "appimage link: $(basename "$dest"): downloaded."
      UPDATED=1
      sed -i "/^$(basename "$dest")|/d" "$state" 2>/dev/null || true
      echo "$(basename "$dest")|$etag|$lastmod" >> "$state"
    else
      rm -f "$tmp"
      log "appimage link: $(basename "$dest"): download FAILED"
      PARTIAL=1
    fi
  done < "$conf"
}

fwupd_check() {
  if fwupdmgr get-updates >"$TMP" 2>&1; then
    if grep -qi "No updatable devices" "$TMP"; then
      log "check: firmware: none."; echo 0
    else
      cat "$TMP"; log "check: firmware: updates available."; echo 1
    fi
  else
    if grep -qi "No updatable devices" "$TMP"; then
      log "check: firmware: none."; echo 0
    else
      cat "$TMP" >&2; return 1
    fi
  fi
}

fwupd_update() {
  echo "--- firmware (fwupd) ---"
  FWUPD_CACHE="${FWUPD_CACHE:-/var/cache/fwupd}"
  if [ -n "$(find "$FWUPD_CACHE" -maxdepth 2 -name '*.xml*' -newermt '-24 hours' 2>/dev/null | head -n 1)" ]; then
    log "fwupd refresh: metadata fresh (<24h), skipping download."
  elif fwupdmgr refresh >"$TMP" 2>&1; then
    cat "$TMP"
    grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
  else
    cat "$TMP"
    if grep -qiE "up to date|no .* (available|to do)|nothing to do" "$TMP"; then
      log "fwupdmgr refresh: metadata up to date."
    else
      FAILED=1
      log "fwupdmgr refresh: FAILED"
      grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    fi
  fi
  if fwupdmgr update -y >"$TMP" 2>&1; then
    cat "$TMP"
    if ! grep -qi "No updatable devices" "$TMP"; then
      UPDATED=1
      grep -viE "^Idle|^$" "$TMP" >> "$LOG" || true
    else
      log "fwupd update: no updatable devices."
    fi
  else
    cat "$TMP"
    if grep -qi "No updatable devices" "$TMP"; then
      log "fwupd update: no updatable devices."
    else
      FAILED=1
      log "fwupd update: FAILED"
      grep -iE "error|failed|warning" "$TMP" >> "$LOG" || true
    fi
  fi
}

# Check-only mode: report available updates without installing.
if [ "${1:-}" = "--check" ]; then
  trim_log
  say "=== check $(date) [$PM_LABEL] ==="
  CHECK_FAIL=0
  ZYPPER_N=0; PACKMAN_N=0; FLAT_N=0; FW_N=0; SYS_HIT=0
  EXTRA_N=0

  # all four queries run concurrently; each job owns a private TMP so
  # outputs can't collide. results collected below in fixed order.
  PMF="$TMP.pmf"
  ( JT=$(mktemp /tmp/maidau-job.XXXXXX); trap 'rm -f "$JT"' EXIT; TMP="$JT";
    ZYPPER_N=0; PACKMAN_N=0; SYS_HIT=0; EXTRA_N=0; UPDATED=0
    if pm_check >"$JT.out" 2>&1; then RC=0; else RC=1; fi
    { echo "RC=$RC"; echo "ZYPPER_N=$ZYPPER_N"; echo "PACKMAN_N=$PACKMAN_N";
      echo "SYS_HIT=$SYS_HIT"; echo "EXTRA_N=$EXTRA_N"; echo "UPDATED=$UPDATED"; } >"$PMF"
    cat "$JT.out" ) >"$TMP.pmlog" 2>&1 &
  PMPID=$!
  ( TMP=$(mktemp /tmp/maidau-job.XXXXXX); trap 'rm -f "$TMP"' EXIT;
    if out=$(flatpak_check); then echo "RC=0 VAL=$out"; else echo "RC=1 VAL=0"; fi ) >"$TMP.flat" 2>&1 &
  FLPID=$!
  ( TMP=$(mktemp /tmp/maidau-job.XXXXXX); trap 'rm -f "$TMP"' EXIT;
    if out=$(fwupd_check); then echo "RC=0 VAL=$out"; else echo "RC=1 VAL=0"; fi ) >"$TMP.fw" 2>&1 &
  FWDPID=$!
  ( TMP=$(mktemp /tmp/maidau-job.XXXXXX); trap 'rm -f "$TMP"' EXIT;
    UPDATED=0
    if out=$(controllers_hook check); then echo "RC=0 VAL=$out UPDATED=$UPDATED"; else echo "RC=1 VAL=0 UPDATED=$UPDATED"; fi ) >"$TMP.ctrl" 2>&1 &
  CTLPID=$!
  ( TMP=$(mktemp /tmp/maidau-job.XXXXXX); trap 'rm -f "$TMP"' EXIT;
    if out=$(appimage_check); then echo "RC=0 VAL=$out"; else echo "RC=1 VAL=0"; fi ) >"$TMP.appimg" 2>&1 &
  APID=$!
  wait "$PMPID"; wait "$FLPID"; wait "$FWDPID"; wait "$CTLPID"; wait "$APID"
  cat "$TMP.pmlog" "$TMP.flat" "$TMP.fw" "$TMP.ctrl" "$TMP.appimg" 2>/dev/null
  if [ -f "$PMF" ]; then . "$PMF"; else CHECK_FAIL=1; log "check: $PM_LABEL query FAILED"; fi
  if [ "${RC:-}" != "0" ]; then CHECK_FAIL=1; log "check: $PM_LABEL query FAILED"; fi
  FLAT_RC=$(sed -n 's/^RC=\([01]\) VAL=.*/\1/p' "$TMP.flat" | tail -n 1)
  FLAT_N=$(sed -n 's/^RC=[01] VAL=\([^ ]*\).*/\1/p' "$TMP.flat" | tail -n 1)
  FW_RC=$(sed -n 's/^RC=\([01]\) VAL=.*/\1/p' "$TMP.fw" | tail -n 1)
  FW_N=$(sed -n 's/^RC=[01] VAL=\([^ ]*\).*/\1/p' "$TMP.fw" | tail -n 1)
  CTL_RC=$(sed -n 's/^RC=\([01]\) VAL=.*/\1/p' "$TMP.ctrl" | tail -n 1)
  CTRL_N=$(sed -n 's/^RC=[01] VAL=\([^ ]*\).*/\1/p' "$TMP.ctrl" | tail -n 1)
  CTL_UPD=$(sed -n 's/^RC=[01] VAL=[^ ]* UPDATED=\([01]\)/\1/p' "$TMP.ctrl" | tail -n 1)
  APPIMG_RC=$(sed -n 's/^RC=\([01]\) VAL=.*/\1/p' "$TMP.appimg" | tail -n 1)
  APPIMG_N=$(sed -n 's/^RC=[01] VAL=\([^ ]*\).*/\1/p' "$TMP.appimg" | tail -n 1)
  if [ "$FLAT_RC" != "0" ]; then CHECK_FAIL=1; log "check: flatpak query FAILED"; fi
  if [ "$FW_RC" != "0" ]; then CHECK_FAIL=1; log "check: firmware query FAILED"; fi
  if [ "$CTL_RC" != "0" ]; then CHECK_FAIL=1; log "check: controllers query FAILED"; fi
  if [ "$APPIMG_RC" != "0" ]; then CHECK_FAIL=1; log "check: appimage query FAILED"; fi
  if [ "$CTL_UPD" = "1" ]; then UPDATED=1; fi
  CTRL_N=${CTRL_N:-0}; FLAT_N=${FLAT_N:-0}; FW_N=${FW_N:-0}; APPIMG_N=${APPIMG_N:-0}
  SNAP_NOW=$(snap_last_q); [ -n "$SNAP_NOW" ] && log "check: latest snapshot #$SNAP_NOW (rollback available)."

  TOTAL=$((ZYPPER_N + FLAT_N + FW_N + CTRL_N + APPIMG_N))
  if [ "$CHECK_FAIL" -ne 0 ]; then
    notify "Update check failed" "Check $LOG" critical dialog-error
  elif [ "$TOTAL" -eq 0 ]; then
    notify "System up to date" "$(last_info)" normal software-update-available
    echo "System up to date."
  elif [ "$SYS_HIT" -eq 1 ] || [ "$FW_N" -eq 1 ]; then
    notify "System update available" "Big update: $PM_LABEL ${ZYPPER_N} (extra ${EXTRA_N}), flatpak ${FLAT_N}, firmware ${FW_N}, controllers ${CTRL_N}. Run System Updater." normal software-update-urgent
    echo "System update available (core/firmware). $PM_LABEL=${ZYPPER_N} extra=${EXTRA_N} flatpak=${FLAT_N} firmware=${FW_N} controllers=${CTRL_N}"
  else
    notify "App updates available" "$PM_LABEL ${ZYPPER_N} (extra ${EXTRA_N}), flatpak ${FLAT_N}, controllers ${CTRL_N}, appimages ${APPIMG_N}. No reboot needed - run System Updater." normal software-update-available
    echo "App updates available, no reboot needed. $PM_LABEL=${ZYPPER_N} extra=${EXTRA_N} flatpak=${FLAT_N} controllers=${CTRL_N} appimg=${APPIMG_N}"
  fi
  say "=== check done ($PM_LABEL=$ZYPPER_N extra=$EXTRA_N flatpak=$FLAT_N firmware=$FW_N controllers=$CTRL_N appimg=$APPIMG_N system=$SYS_HIT) ==="
  if [ -t 1 ]; then
    echo ""; read -n1 -s -r -p "Done - press any key to close..."; echo ""
  fi
  exit 0
fi

trim_log
say "=== $(date) [$PM_LABEL] ==="

LAST_MSG=$(last_info)
say "$LAST_MSG"
if [ -f "$LASTFILE" ]; then
  NOW_EPOCH=$(date +%s); LAST_EPOCH=$(head -n1 "$LASTFILE")
  AGE_DAYS=$(( (NOW_EPOCH - LAST_EPOCH) / 86400 ))
  if [ "$AGE_DAYS" -gt "$STALE_DAYS" ]; then
    say "WARNING: last successful update was ${AGE_DAYS}d ago (stale > ${STALE_DAYS}d)."
  fi
fi

# controller drivers are opt-in: say so BEFORE anything changes
if [ "$PM" = "zypper" ] && [ -x "$HOME/.local/bin/setup-controllers.sh" ] && [ "${UPDATE_CONTROLLERS:-0}" != "1" ]; then
  say "controllers: skipped (Bazzite KMP stack). to include them: UPDATE_CONTROLLERS=1 update-all.sh"
fi
FLATF="$TMP.flatup"; FLATRF="$TMP.flatres"
( JT=$(mktemp /tmp/maidau-job.XXXXXX); trap 'rm -f "$JT"' EXIT; TMP="$JT";
  UPDATED=0; FAILED=0
  flatpak_update >"$JT.out" 2>&1
  echo "BG_UPDATED=$UPDATED BG_FAILED=$FAILED" >"$FLATRF"
  cat "$JT.out" ) >"$FLATF" 2>&1 &
FLPID=$!
# strict mode: refuse system upgrades with no snapshot tooling at all
if [ "$REQUIRE_SNAP" = "1" ] && ! snap_has_tools; then
  say "ABORT: --require-snapshot but no snapper/timeshift available."
  notify "Update aborted" "No snapshot tooling for --require-snapshot." critical dialog-error
  wait "$FLPID" 2>/dev/null || true
  exit 2
fi
# metadata was just refreshed above: later zypper installs in this run
# skip re-downloading it (setup-controllers honors this env var)
export ZYPPER_NO_REFRESH=1
if pm_update; then :; else FAILED=1; fi
[ "${AUR_FAILED:-0}" = "1" ] && PARTIAL=1
wait "$FLPID"
cat "$FLATF" 2>/dev/null
if [ -f "$FLATRF" ]; then . "$FLATRF"; else FAILED=1; log "flatpak: result lost"; fi
[ "${BG_UPDATED:-0}" = "1" ] && UPDATED=1
[ "${BG_FAILED:-0}" = "1" ] && FAILED=1
controllers_hook update
appimage_update
fwupd_update

say "=== done (failed=$FAILED updated=$UPDATED important=$IMPORTANT) ==="
[ -n "$SNAP_INFO" ] && say "safety: $SNAP_INFO"

REBOOT_NEEDED=0
if [ "$UPDATED" -eq 1 ]; then
  if [ "$IMPORTANT" -eq 1 ]; then
    REBOOT_NEEDED=1
  fi
  FW_MSG=$(fwupdmgr check-reboot-needed 2>&1 || true)
  if ! echo "$FW_MSG" | grep -qi "No reboot"; then
    REBOOT_NEEDED=1
  fi
fi

if [ "$FAILED" -eq 0 ]; then
  date +%s > "$LASTFILE"
  if [ "$PARTIAL" -eq 1 ]; then
    notify "Update finished partially" "$(last_info). A non-core step failed (see AUR/log). Log: $LOG" normal dialog-warning
  elif [ "$UPDATED" -eq 0 ]; then
    notify "System up to date" "$(last_info)" normal software-update-available
  elif [ "$REBOOT_NEEDED" -eq 1 ]; then
    notify "System updated - reboot recommended" "$(last_info). Reboot when ready. Log: $LOG${SNAP_INFO:+ Snaps: $SNAP_INFO}" normal software-update-urgent
  else
    notify "System updated" "$(last_info). Flatpak + $PM_LABEL + controllers + firmware done.${SNAP_INFO:+ Snaps: $SNAP_INFO}" normal software-update-available
  fi
else
  notify "Update finished with errors" "$(last_info). Check $LOG" critical dialog-error
fi

# Notify-only: this script NEVER reboots. User reboots manually when ready.
if [ "$REBOOT_NEEDED" -eq 1 ]; then
  say "--- reboot recommended (kernel/systemd/firmware) - reboot manually when ready ---"
fi

# Release single-press lock before interactive tail prompts,
# so a Done-waiting window doesn't block the next run.
exec 200>&-

# Keep terminal window open so output stays visible
if [ -t 1 ]; then
  echo ""
  read -n1 -s -r -p "Done - press any key to close..."
  echo ""
fi
