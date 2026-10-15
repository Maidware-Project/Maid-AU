#!/bin/bash
# Bazzite-equivalent controller stack for openSUSE Tumbleweed
# Mirrors what Bazzite/OGC provides, using native Tumbleweed packages:
#   - kernel built-in (already in Tumbleweed 7.2.x): xpad, hid-nintendo,
#     hid-playstation, hid-sony, hid-microsoft, joydev
#   - kmods (Bazzite installs via akmods): xone, new-lg4ff, hid-tmff2, gcadapter
#     -> on Tumbleweed: xone-kmp-default, hid-tmff2-kmp-default (+ xpadneo for BT)
#   - userspace (Bazzite): inputplumber, joycond, steam-devices, bluez
#
# Usage:
#   setup-controllers.sh            # interactive, uses sudo
#   setup-controllers.sh --update   # non-interactive, uses sudo -n (for updater)
#   XONEDO=1 setup-controllers.sh   # also build xonedo (Bazzite's xpad-friendly xone fork) via DKMS
#
# Idempotent: safe to run on every update.

set -o pipefail
MODE="${1:-}"
if [ "$MODE" = "--update" ]; then
  SUDO="sudo -n"
else
  SUDO="sudo"
fi

LOG="$HOME/.local/share/update-all.log"
log() { echo "$*" >> "$LOG"; }

# Tumbleweed native equivalents of Bazzite akmods + userspace.
# NOTE: openSUSE ships classic xone (blacklists xpad for Xbox One pads).
# Bazzite now uses xonedo (keeps xpad). See XONEDO=1 below.
PKGS=(
  xone-kmp-default
  xone-dongle-firmware
  xpadneo-kmp-default
  joycond
  joycond-autoload
  inputplumber
  hid-tmff2-kmp-default
  steam-devices
  bluez
  kernel-firmware
)

say() { echo "$*"; log "$*"; }

say "--- controllers (bazzite-equivalent) ---"

# 1. Install / update packages (zypper dup in updater already covers updates,
#    but explicit install guarantees they stay present after kernel flips)
# Private temp log (mktemp, not a fixed /tmp path): a pre-placed symlink
# at a fixed path could redirect this script's output elsewhere.
CTRL_LOG="$(mktemp -t ctrl-install-XXXXXX.log)" || { say "controllers: no temp file, skipping"; exit 1; }
trap 'rm -f "$CTRL_LOG"' EXIT
if $SUDO zypper --non-interactive install --no-confirm ${ZYPPER_NO_REFRESH:+--no-refresh} "${PKGS[@]}" > "$CTRL_LOG" 2>&1; then
  cat "$CTRL_LOG"
  if grep -qiE "Nothing to do|already installed|up to date|No updates" "$CTRL_LOG"; then
    log "controllers: packages up to date."
  else
    grep -E "Installing|Updating|installing|updating|going to be" "$CTRL_LOG" >> "$LOG" 2>/dev/null || true
  fi
else
  cat "$CTRL_LOG"
  log "controllers: zypper install FAILED"
  grep -iE "error|failed" "$CTRL_LOG" >> "$LOG" 2>/dev/null || true
  # don't abort updater on controller failure; report and continue
  [ "$MODE" = "--update" ] || exit 1
fi

# 2. KMP sanity: after a kernel update the kmp must match `uname -r`.
#    Tumbleweed publishes kmp per kernel (e.g. 0.5.8_k7.2.9_1). If mismatch,
#    zypper dup usually fixes it on next run; flag it here.
KREL="$(uname -r)"
for kmod in xone_dongle hid-xpadneo hid-tmff-new; do
  if ! /sbin/modinfo "$kmod" >/dev/null 2>&1; then
    say "controllers: WARNING $kmod has no modinfo for $KREL (reboot or zypper dup pending?)"
    log "controllers: kmp mismatch $kmod on $KREL"
  fi
done

# 3. Firmware for Xbox wireless dongle (proprietary, downloaded on install).
#    Tumbleweed path is /usr/lib/firmware (not /lib/firmware).
#    Re-run the downloader if firmware missing (e.g. after kernel switch).
if ls /usr/lib/firmware/xone_dongle_*.bin >/dev/null 2>&1; then
  log "controllers: dongle fw present."
elif [ ! -f /lib/firmware/xone-dongle.bin ] && [ ! -f /lib/firmware/xow_dongle.bin ]; then
  say "controllers: xbox dongle firmware missing, running downloader..."
  if [ -x /usr/libexec/xone-fw-download ] || [ -x /usr/sbin/xone-fw-download ]; then
    $SUDO /usr/libexec/xone-fw-download 2>&1 || $SUDO /usr/sbin/xone-fw-download 2>&1 || log "controllers: dongle fw download failed (agree to MS ToU on manual run)"
  else
    log "controllers: dongle fw downloader not found, run manually after plugging dongle"
  fi
fi

# 4. User must be in `input` group (Bazzite does `ujust add-user-to-input`).
if ! id -nG "$USER" | grep -qw input; then
  say "controllers: adding $USER to 'input' group (re-login required once)..."
  $SUDO /usr/sbin/usermod -aG input "$USER" && log "controllers: added $USER to input" || log "controllers: usermod input FAILED"
else
  log "controllers: user in input group ok."
fi

# 5. Enable services Bazzite enables: inputplumber, bluetooth, joycond.
for svc in bluetooth inputplumber joycond; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    if ! systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
      say "controllers: enabling ${svc}.service..."
      $SUDO /usr/bin/systemctl enable --now "${svc}.service" 2>&1 || log "controllers: enable $svc FAILED"
    else
      # keep running; restart inputplumber after update so new build takes effect
      if [ "$MODE" = "--update" ] && [ "$svc" = "inputplumber" ]; then
        $SUDO /usr/bin/systemctl try-restart "${svc}.service" 2>/dev/null || true
      fi
      log "controllers: $svc enabled ok."
    fi
  fi
done

# 6. Optional: xonedo (Bazzite's xpad-compatible xone fork).
#    openSUSE only ships classic xone which disables xpad for Xbox One pads.
#    If you need Xbox 360 + Xbox One pads at the same time, rebuild as xonedo:
if [ "${XONEDO:-0}" = "1" ]; then
  say "controllers: XONEDO=1 requested, building OpenGamingCollective/xonedo via DKMS..."
  SRC="/usr/src/xonedo-0.1"
  if [ ! -d "$SRC" ]; then
    $SUDO zypper --non-interactive install --no-confirm ${ZYPPER_NO_REFRESH:+--no-refresh} dkms kernel-default-devel curl bsdtar 2>&1 | tail -n 5
    $SUDO /usr/bin/git clone https://github.com/OpenGamingCollective/xonedo.git "$SRC" 2>&1 | tail -n 3
  fi
  ( cd "$SRC" && $SUDO /usr/bin/git pull --ff-only 2>&1 | tail -n 3; $SUDO /usr/sbin/dkms install -m xonedo -v 0.1 --force 2>&1 | tail -n 10 )
  $SUDO /usr/sbin/modprobe xonedo 2>&1 || true
  log "controllers: xonedo build attempted (see above)."
fi

say "controllers: done."
