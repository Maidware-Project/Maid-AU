#!/usr/bin/env bash
# One-button system updater: flatpak + native packages + firmware.
# Backends in pm-*.sh (zypper/dnf/pacman/apt), auto-detected, override with UPDATE_PM.
LOG="$HOME/.local/share/update-all.log"
LASTFILE="$HOME/.local/share/update-all.last"
STALE_DAYS=3
mkdir -p "$(dirname "$LOG")"

# flags: --require-snapshot aborts the system upgrade unless snapshots work.
# May appear anywhere in argv; the rest keeps positional meaning.
# Array (not string concat): keeps arguments with spaces/globs intact.
REQUIRE_SNAP=0
POSARGS=()
for _a in "$@"; do
  if [ "$_a" = "--require-snapshot" ]; then REQUIRE_SNAP=1
  else POSARGS+=("$_a"); fi
done
if [ "${#POSARGS[@]}" -gt 0 ]; then
  set -- "${POSARGS[@]}"
else
  set --
fi

notify() {
  # The GUI shows its own notifications; ask it to skip ours so a check
  # does not pop the same message twice.
  [ "${UPDATE_NO_NOTIFY:-0}" = "1" ] && return 0
  local summary="$1"; local body="${2:-}"; local urgency="${3:-normal}"; local icon="${4:-software-update-available}"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "System Updater" -u "$urgency" -i "$icon" "$summary" "$body"
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --passivepopup "$summary $body" 5
  else
    echo "$summary $body"
  fi
}

last_info() {
  if [ -f "$LASTFILE" ]; then
    local last_epoch now age age_h age_d last_date
    last_epoch=$(head -n1 "$LASTFILE" 2>/dev/null || echo 0)
    case "$last_epoch" in ''|*[!0-9]*) last_epoch=0 ;; esac
    if [ "$last_epoch" -eq 0 ]; then
      echo "No record of previous successful update."
      return 0
    fi
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
trap 'rm -f "$TMP" "$TMP".*' EXIT

log() { echo "$*" >> "$LOG"; }
trim_log() {
  local max_lines=1000
  if [ -f "$LOG" ]; then
    tail -n "$max_lines" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}
say() { echo "$*"; log "$*"; }

# kmp packages are published per kernel flavor: follow the running
# kernel's release suffix (same resolution as
# controllers/setup-controllers.sh).
kmp_flavor() {
  local krel
  krel="$(uname -r)"
  echo "${krel##*-}"
}

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
      *suse*) echo zypper; return ;;
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

# Controller helpers are installed next to update-all.sh (user and system
# installs alike); when running straight from a checkout they live in
# ../controllers. Fall back to the old ~/.local/bin location for upgrades
# from older installs.
ctrl_script() {
  local name="$1" d
  for d in "$HOME/.local/bin" "$BACKEND_DIR" "$BACKEND_DIR/../controllers"; do
    if [ -x "$d/$name" ]; then printf '%s' "$d/$name"; return 0; fi
  done
  return 1
}
SETUP_CTRL=$(ctrl_script setup-controllers.sh || true)
CHECK_CTRL=$(ctrl_script check-controllers.sh || true)
GAMEPAD_HELPER="$HOME/.local/bin/mod-gamepad.sh"
if [ ! -x "$GAMEPAD_HELPER" ]; then
  GAMEPAD_HELPER=$(command -v mod-gamepad.sh 2>/dev/null || true)
fi

# ---- sudo: passwordless preferred, graphical askpass for the GUI, then tty ----
# The GUI sets MAID_AU_GUI=1 and SUDO_ASKPASS; sudo -A then asks through a
# dialog instead of requiring a terminal. If credentials are cached, sudo
# uses them without showing the dialog.
if [ "${MAID_AU_GUI:-0}" = "1" ] && [ -n "${SUDO_ASKPASS:-}" ]; then
  SUDO="sudo -A"
elif sudo -n true >/dev/null 2>&1; then
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
  if [ "$PM" = "zypper" ] && [ -n "$SETUP_CTRL" ]; then
    if [ "$1" = "update" ]; then
      echo "--- controllers (auto-update) ---"
      if "$SETUP_CTRL" --update >"$TMP" 2>&1; then
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
      if [ -n "$CHECK_CTRL" ]; then
        if "$CHECK_CTRL" --short >"$TMP" 2>&1; then
          log "controllers check: healthy."
        else
          cat "$TMP"
          log "controllers check: issues found (see above)."
          grep -E "FAIL|WARN" "$TMP" >> "$LOG" || true
        fi
      fi
    else
      CTRL_N=0
      # shellcheck disable=SC2024  # $TMP is user-owned: the redirect stays with the user
      if $SUDO zypper --non-interactive list-updates >"$TMP" 2>&1; then
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
      # the kmp names carry the kernel flavor: ask for the ones built
      # for the kernel this machine runs.
      _kfl="$(kmp_flavor)"
      for _cp in "xone-kmp-$_kfl" "xpadneo-kmp-$_kfl" joycond inputplumber "hid-tmff2-kmp-$_kfl"; do
        if ! rpm -q "$_cp" >/dev/null 2>&1; then CTRL_N=$((CTRL_N+1)); UPDATED=1; log "check: controllers: $_cp missing."; break; fi
      done
      echo "$CTRL_N"
    fi
  else
    if [ -n "$GAMEPAD_HELPER" ]; then
      # Maid Helper owns multi-distro gamepads; AU just drives it.
      if [ "$1" = "check" ]; then
        if "$GAMEPAD_HELPER" check >"$TMP" 2>&1; then
          log "check: controllers: helper reports healthy."
        else
          cat "$TMP"; log "check: controllers: helper reports issues (see above)."
        fi
        echo 0
      else
        echo "--- controllers via Maid Helper ---"
        if "$GAMEPAD_HELPER" fix >"$TMP" 2>&1; then
          cat "$TMP"; log "controllers: helper run ok."
        else
          cat "$TMP"; log "controllers: helper run needs attention."
          PARTIAL=1
        fi
      fi
    else
      log "controllers: backend '$PM' has no controller hook (Maid Helper adds gamepads here)."
      [ "$1" = "check" ] && echo 0
    fi
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
  while IFS= read -r d; do
    find "$d" -maxdepth 2 -type f -name "*.AppImage" 2>/dev/null
  done < <(appimage_dirs)
}

appimage_check() {
  # echo count of managed AppImages (embedded info + configured links)
  local n=0 f
  if command -v appimageupdatetool >/dev/null 2>&1; then
    while IFS= read -r f; do
      if echo n | appimageupdatetool "$f" 2>&1 | grep -qiE "update (available|found)|new version|up to date|already"; then
        n=$((n+1))
      fi
    done < <(appimage_files)
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
    while IFS= read -r f; do
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
    done < <(appimage_files)
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
  local name url sha pin dest etag lastmod cached tmp got hexonly
  while IFS='|' read -r name url sha _rest; do
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$url" ] || continue
    # fail closed: plaintext URLs never fetch, malformed pins never install.
    case "$url" in
      https://*) : ;;
      *) log "appimage link: $name: refused (not https) - left alone"; PARTIAL=1; continue ;;
    esac
    pin=""
    if [ -n "${sha:-}" ]; then
      hexonly=$(echo "$sha" | tr -d '0-9a-fA-F')
      if [ -z "$hexonly" ] && [ "${#sha}" = "64" ]; then
        pin="$sha"
      else
        log "appimage link: $name: bad pinned hash (want 64 hex chars) - left alone"
        PARTIAL=1
        continue
      fi
    fi
    dest=$(appimage_files | grep -F -m1 "/$(basename "$name" .AppImage)" || true)
    if [ -z "$dest" ]; then
      dest="$HOME/AppImages/$(basename "$name")"
      [ "${dest%.AppImage}" = "$dest" ] && dest="$dest.AppImage"
    fi
    etag=$(curl -sI --proto '=https' "$url" 2>/dev/null | grep -i '^etag:' | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]: *//;s/ *$//')
    lastmod=$(curl -sI --proto '=https' "$url" 2>/dev/null | grep -i '^last-modified:' | tr -d '\r' | sed 's/^[Ll]ast-[Mm]odified: *//;s/ *$//')
    cached=$(grep -m1 "^$(basename "$dest")|" "$state" 2>/dev/null || true)
    if [ -n "$etag$lastmod" ] && [ "$cached" = "$(basename "$dest")|$etag|$lastmod" ]; then
      log "appimage link: $(basename "$dest"): unchanged, skipped."
      continue
    fi
    tmp=$(mktemp /tmp/maidau-appimg.XXXXXX) || continue
    if curl -sL --proto '=https' --max-time 300 -o "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
      if [ -n "$pin" ]; then
        got=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
        if [ "$got" != "$pin" ]; then
          rm -f "$tmp"
          log "appimage link: $(basename "$dest"): HASH MISMATCH (got ${got:-none}) - left alone"
          PARTIAL=1
          continue
        fi
      fi
      mkdir -p "$(dirname "$dest")"
      if [ -e "$dest" ] && ! cp -a "$dest" "${dest}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
        rm -f "$tmp"
        log "appimage link: $(basename "$dest"): backup FAILED - left alone"
        PARTIAL=1
        continue
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

# ---- maid suite: the updater knows about its own family ----
# Only Maid-family repos are tracked here: Maid BT, Maidshare,
# Maid Watcher, Maid Helper and Maid Runner, all under
# github.com/Maidware-Project. A checkout you already have is found by
# its github origin (so where it sits on disk does not matter) and
# pulled --ff-only; one that is not on disk yet is cloned from github
# into ~/.local/share/maid-au/suite. The Nuclear plugin and the Atrim
# launcher are separate projects with their own releases - never touch
# them from here. Opt out of check + pull + clone with MAID_SUITE=0.
# Pulls are --ff-only (diverged trees are left alone and reported);
# deploying still means rerunning each install.sh.
#
# MAID_SUITE_LIST overrides the family (one "Name|url" per line) - the
# tests use it, and so can anyone mirroring the suite elsewhere.
maid_suite_list() {
  if [ -n "${MAID_SUITE_LIST:-}" ]; then
    printf '%s\n' "$MAID_SUITE_LIST"; return 0
  fi
  # Maid Watcher is not published on its own - it ships inside Maid BT
  # (watcher/), so pulling Maid BT covers it.
  cat <<'LIST'
Maid BT|https://github.com/Maidware-Project/Maid-BT.git
Maidshare|https://github.com/Maidware-Project/Maidshare.git
Maid Helper|https://github.com/Maidware-Project/Maid-Helper.git
Maid Runner|https://github.com/Maidware-Project/Maid-Runner.git
LIST
}

maid_clone_root() {
  echo "${XDG_DATA_HOME:-$HOME/.local/share}/maid-au/suite"
}

maid_norm_url() {
  # owner/repo form, so https and ssh remotes compare equal
  local u="${1%.git}"
  case "$u" in
    git@github.com:*)     u="${u#git@github.com:}" ;;
    https://github.com/*) u="${u#https://github.com/}" ;;
    http://github.com/*)  u="${u#http://github.com/}" ;;
  esac
  printf '%s' "$u"
}

maid_find() {
  # echo the checkout whose github origin matches $1, else nothing
  local want base d got
  want=$(maid_norm_url "$1")
  for base in "$HOME/Documents/GitHub" "$HOME/GitHub" "$HOME/Projects" \
              "$HOME/src" "$HOME/code" "$(maid_clone_root)"; do
    [ -d "$base" ] || continue
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      got=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
      if [ "$(maid_norm_url "$got")" = "$want" ]; then
        echo "$d"; return 0
      fi
    done < <(find "$base" -maxdepth 3 -type d -name .git -printf '%h\n' 2>/dev/null)
  done
  return 1
}

maid_behind() {
  # echo behind-count for one repo (0 when unknown/offline/no upstream)
  git -C "$1" fetch --quiet 2>/dev/null || { echo 0; return 0; }
  git -C "$1" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0
}

maidsuite_check() {
  if [ "${MAID_SUITE:-1}" = "0" ]; then
    log "check: maid suite: skipped (MAID_SUITE=0)."; echo 0; return 0
  fi
  local line name url d behind n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%|*}"; url="${line#*|}"
    if d=$(maid_find "$url"); then
      behind=$(maid_behind "$d")
      if [ "${behind:-0}" -gt 0 ] 2>/dev/null; then
        log "check: maid suite: $name: $behind commit(s) behind."
        n=$((n + 1))
      fi
    else
      log "check: maid suite: $name: not on disk yet (a run will clone it)."
      n=$((n + 1))
    fi
  done < <(maid_suite_list)
  [ "$n" -eq 0 ] && log "check: maid suite: up to date."
  echo "$n"
}

maidsuite_update() {
  echo "--- maid suite (own tools) ---"
  if [ "${MAID_SUITE:-1}" = "0" ]; then
    say "maid suite: disabled (MAID_SUITE=0) - skipping."
    log "maid suite: skipped (MAID_SUITE=0)."; return 0
  fi
  say "maid suite: enabled - pulling from github Maid BT, Maidshare, Maid Watcher, Maid Helper, Maid Runner."
  local line name url d behind before statline c changed=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%|*}"; url="${line#*|}"
    if d=$(maid_find "$url"); then
      behind=$(maid_behind "$d")
      [ "${behind:-0}" -gt 0 ] 2>/dev/null || continue
      before=$(git -C "$d" rev-parse HEAD 2>/dev/null || true)
      if git -C "$d" pull --ff-only >/dev/null 2>&1; then
        log "maid suite: $name: updated ($behind)."
        while IFS= read -r c; do log "maid suite:   $c"; done < <(git -C "$d" log --oneline "$before..HEAD" 2>/dev/null || true)
        statline=$(git -C "$d" diff --stat "$before..HEAD" 2>/dev/null | tail -n 1)
        [ -n "$statline" ] && log "maid suite:   files: $statline"
        changed=1
        maidsuite_deploy "$name" "$d"
      else
        log "maid suite: $name: needs attention (diverged?) - left alone."
        PARTIAL=1
      fi
    else
      d="$(maid_clone_root)/$(basename "${url%.git}")"
      mkdir -p "$(dirname "$d")" 2>/dev/null || true
      if git clone --quiet "$url" "$d" >/dev/null 2>&1; then
        log "maid suite: $name: cloned from github ($url)."
        changed=1
        maidsuite_deploy "$name" "$d"
      else
        log "maid suite: $name: could not clone ($url) - skipped."
      fi
    fi
  done < <(maid_suite_list)
  [ "$changed" = "1" ] && UPDATED=1
  return 0
}

maidsuite_deploy() {
  # Rerun a project's installer after its code updated. Opt-in via
  # UPDATE_MAID_DEPLOY=1 (default off: installers enable services).
  # stdin is /dev/null so interactive prompts skip themselves.
  local name="$1" d="$2"
  [ "${UPDATE_MAID_DEPLOY:-0}" = "1" ] || {
    log "maid suite: $name: code updated; rerun its install.sh to deploy (or set UPDATE_MAID_DEPLOY=1)."
    return 0
  }
  [ -x "$d/install.sh" ] || {
    log "maid suite: $name: no installer - deploy manually."
    return 0
  }
  log "maid suite: $name: UPDATE_MAID_DEPLOY=1 - rerunning install.sh on the commits above."
  if ( cd "$d" && bash install.sh --no-packages </dev/null >/dev/null 2>&1 ); then
    log "maid suite: $name: redeployed."
  elif ( cd "$d" && bash install.sh </dev/null >/dev/null 2>&1 ); then
    log "maid suite: $name: redeployed."
  else
    log "maid suite: $name: redeploy FAILED - run its install.sh by hand."
    PARTIAL=1
  fi
  return 0
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
  # readable output: the package-manager job prints for people outright.
  # the other jobs emit machine protocol that the parsers below read from
  # their dedicated files - cat'ing those raw used to print "RC=0 VAL=0"
  # noise into the check output. the controllers helper embeds report
  # text inside its protocol line, so lift that text out and print it
  # without the markers; bare counts stay machine-side.
  cat "$TMP.pmlog" "$TMP.ctrl" 2>/dev/null | awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        sub(/^RC=[0-9]+ VAL=/, "", l)
        if (l ~ / UPDATED=[0-9]+$/ || l ~ /^[0-9]+$/) continue
        if (l != "") print l
      }
    }'
  # shellcheck disable=SC1090  # result file written by this script
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
  MAID_N=$(maidsuite_check)
  if [ "${MAID_SUITE:-1}" = "0" ]; then
    say "maid suite: disabled (MAID_SUITE=0) - not checked, not updated."
  elif [ "$MAID_N" -gt 0 ]; then
    say "maid suite: $MAID_N repo(s) behind or missing - run the updater to pull them."
  else
    say "maid suite: up to date."
  fi
  SNAP_NOW=$(snap_last_q); [ -n "$SNAP_NOW" ] && log "check: latest snapshot #$SNAP_NOW (rollback available)."

  TOTAL=$((ZYPPER_N + EXTRA_N + FLAT_N + FW_N + CTRL_N + APPIMG_N + MAID_N))
  if [ "$CHECK_FAIL" -ne 0 ]; then
    notify "Update check failed" "Check $LOG" critical dialog-error
    say "=== check done ($PM_LABEL=$ZYPPER_N extra=$EXTRA_N flatpak=$FLAT_N firmware=$FW_N controllers=$CTRL_N appimg=$APPIMG_N maid=$MAID_N system=$SYS_HIT failed=1) ==="
    echo "Check failed - the package manager could not complete the preview. See $LOG."
    if [ -t 1 ]; then
      echo ""; read -n1 -s -r -p "Done - press any key to close..."; echo ""
    fi
    exit 1
  elif [ "$TOTAL" -eq 0 ]; then
    notify "System up to date" "$(last_info)" normal software-update-available
    echo "System up to date."
  elif [ "$SYS_HIT" -eq 1 ] || [ "$FW_N" -eq 1 ]; then
    notify "System update available" "Big update: $PM_LABEL ${ZYPPER_N} (extra ${EXTRA_N}), flatpak ${FLAT_N}, firmware ${FW_N}, controllers ${CTRL_N}. Run System Updater." normal software-update-urgent
    echo "System update available (core/firmware). $PM_LABEL=${ZYPPER_N} extra=${EXTRA_N} flatpak=${FLAT_N} firmware=${FW_N} controllers=${CTRL_N}"
  else
    notify "App updates available" "$PM_LABEL ${ZYPPER_N} (extra ${EXTRA_N}), flatpak ${FLAT_N}, controllers ${CTRL_N}, appimages ${APPIMG_N}, maid ${MAID_N}. No reboot needed - run System Updater." normal software-update-available
    echo "App updates available, no reboot needed. $PM_LABEL=${ZYPPER_N} extra=${EXTRA_N} flatpak=${FLAT_N} controllers=${CTRL_N} appimg=${APPIMG_N} maid=${MAID_N}"
  fi
  say "=== check done ($PM_LABEL=$ZYPPER_N extra=$EXTRA_N flatpak=$FLAT_N firmware=$FW_N controllers=$CTRL_N appimg=$APPIMG_N maid=$MAID_N system=$SYS_HIT failed=0) ==="
  if [ -t 1 ]; then
    echo ""; read -n1 -s -r -p "Done - press any key to close..."; echo ""
  fi
  exit 0
fi

trim_log
T_TOT=$(date +%s)
dur_fmt() {
  local s=$1
  printf '%dm%02ds' $((s / 60)) $((s % 60))
}
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
if [ "$PM" = "zypper" ] && [ -n "$SETUP_CTRL" ] && [ "${UPDATE_CONTROLLERS:-0}" != "1" ]; then
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
T_PM=$(date +%s)
if pm_update; then :; else FAILED=1; fi
say "packages: $PM_LABEL took $(dur_fmt $(($(date +%s) - T_PM)))"
[ "${AUR_FAILED:-0}" = "1" ] && PARTIAL=1
wait "$FLPID"
say "flatpak: ran alongside packages, also done"
cat "$FLATF" 2>/dev/null
# shellcheck disable=SC1090  # result file written by this script
if [ -f "$FLATRF" ]; then . "$FLATRF"; else FAILED=1; log "flatpak: result lost"; fi
[ "${BG_UPDATED:-0}" = "1" ] && UPDATED=1
[ "${BG_FAILED:-0}" = "1" ] && FAILED=1
controllers_hook update
appimage_update
maidsuite_update
fwupd_update

say "=== done ($(dur_fmt $(($(date +%s) - T_TOT)))): failed=$FAILED updated=$UPDATED important=$IMPORTANT ==="
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
