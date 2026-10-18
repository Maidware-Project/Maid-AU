#!/bin/bash
# System check for controller support (Bazzite-equivalent on Tumbleweed)
# Usage: check-controllers.sh [--short]
# Exit 0 = healthy, 1 = issues found.

SHORT=0
[ "${1:-}" = "--short" ] && SHORT=1

# the module packages are published per kernel flavor: follow the
# running kernel's release suffix (same resolution as
# setup-controllers.sh).
kmp_flavor() {
  local krel
  krel="$(uname -r)"
  echo "${krel##*-}"
}
FLAVOR="$(kmp_flavor)"

PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); [ "$SHORT" -eq 0 ] && echo "  [OK]   $*"; return 0; }
warn() { WARN=$((WARN+1)); echo "  [WARN] $*"; return 0; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; return 0; }

echo "=== controller system check ($(date +%F\ %T), kernel $(uname -r)) ==="

echo "- kernel drivers (built-in, Tumbleweed):"
for m in xpad hid_nintendo hid_playstation hid_sony hid_microsoft joydev uinput; do
  if [ -f "/lib/modules/$(uname -r)/kernel/drivers/input/joystick/xpad.ko.zst" ] && [ "$m" = "xpad" ]; then ok "$m present"; continue; fi
  if /sbin/modinfo "$m" >/dev/null 2>&1; then ok "$m available"
  else
    # hid drivers live under drivers/hid, modinfo still finds them; if not, check file
    if find "/lib/modules/$(uname -r)" -name "${m}.ko*" 2>/dev/null | grep -q .; then ok "$m present (file)"
    else fail "$m MISSING for $(uname -r)"; fi
  fi
done

echo "- distro packages (Bazzite akmods/userspace equivalents):"
for p in "xone-kmp-$FLAVOR" xone-dongle-firmware "xpadneo-kmp-$FLAVOR" joycond inputplumber "hid-tmff2-kmp-$FLAVOR" steam-devices bluez; do
  if rpm -q "$p" >/dev/null 2>&1; then ok "$p $(rpm -q --queryformat '%{VERSION}' "$p")"
  else warn "$p NOT installed"; fi
done

echo "- kmp matches running kernel:"
KREL="$(uname -r)"
if rpm -q "xone-kmp-$FLAVOR" >/dev/null 2>&1; then
  /sbin/modinfo xone_dongle >/dev/null 2>&1 && ok "xone_dongle loads on $KREL" || warn "xone installed but modinfo fails (reboot pending?)"
  /sbin/modinfo xone_wired >/dev/null 2>&1 && ok "xone_wired loads on $KREL" || warn "xone_wired modinfo fails"
fi
if rpm -q "xpadneo-kmp-$FLAVOR" >/dev/null 2>&1; then
  /sbin/modinfo hid-xpadneo >/dev/null 2>&1 && ok "xpadneo loads on $KREL" || warn "xpadneo installed but modinfo fails (reboot pending?)"
fi
if rpm -q "hid-tmff2-kmp-$FLAVOR" >/dev/null 2>&1; then
  /sbin/modinfo hid-tmff-new >/dev/null 2>&1 && ok "hid-tmff-new loads on $KREL" || warn "hid-tmff2 installed but modinfo fails (reboot pending?)"
fi

echo "- firmware:"
if ls /usr/lib/firmware/xone_dongle_*.bin >/dev/null 2>&1 || ls /lib/firmware/xone_dongle_*.bin >/dev/null 2>&1; then ok "xbox dongle fw present"; else warn "xbox dongle fw missing (only matters for wireless dongle)"; fi

echo "- groups & permissions:"
id -nG "$USER" | grep -qw input && ok "user in input group" || fail "user NOT in input group (run setup-controllers.sh, then re-login)"
[ -c /dev/uinput ] && ok "/dev/uinput present" || fail "/dev/uinput missing"
lsmod | grep -q uinput && ok "uinput loaded" || warn "uinput not loaded (will autoload)"

echo "- services:"
for s in bluetooth inputplumber joycond; do
  if ! systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "${s}.service"; then
    [ "$s" = "bluetooth" ] && fail "$s unit missing" || warn "$s unit missing (pkg not installed?)"
    continue
  fi
  systemctl is-enabled --quiet "${s}.service" 2>/dev/null && ok "$s enabled" || warn "$s disabled"
  systemctl is-active --quiet "${s}.service" 2>/dev/null && ok "$s active" || warn "$s inactive"
done

echo "- bluetooth (for wireless pads):"
command -v bluetoothctl >/dev/null && ok "bluetoothctl $(bluetoothctl --version 2>/dev/null)" || fail "bluetoothctl missing"
bluetoothctl show 2>/dev/null | grep -qi "powered: yes" && ok "bt powered" || warn "bt not powered / no adapter"

echo "- connected pads right now:"
if ls /dev/input/js* >/dev/null 2>&1; then
  ok "joystick nodes: $(ls /dev/input/js* | tr '\n' ' ')"
else
  warn "no /dev/input/js* (no pad connected - normal if none plugged in)"
fi
[ "$SHORT" -eq 0 ] && echo "  event nodes: $(ls /dev/input/event* 2>/dev/null | wc -l) total"

echo "- steam:"
command -v steam >/dev/null && ok "steam native present" || warn "steam not in PATH"
flatpak list --app 2>/dev/null | grep -qi steam && ok "steam flatpak present" || true
rpm -q steam-devices >/dev/null 2>&1 && ok "steam-devices udev rules present" || warn "steam-devices missing"

echo "=== result: $PASS ok, $WARN warnings, $FAIL errors ==="
[ "$FAIL" -eq 0 ]
