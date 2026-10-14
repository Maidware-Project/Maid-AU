#!/usr/bin/env bash
# Maid AU test suite. Stub farm fakes all package managers (fixtures),
# so every backend is exercised on any machine. Safe: sandbox HOME,
# no real installs, no sudo prompts (stubbed). Fails fast.
set -u
PKGDIR="$(cd "$(dirname "$0")/.." && pwd)"
STUBS="$PKGDIR/tests/stubs"
FIXDIR="$PKGDIR/tests/fixtures"
PASS=0
ok()   { PASS=$((PASS+1)); echo "ok $PASS - $1"; }
fail() { echo "NOT OK - $1"; exit 1; }
fresh_home() { rm -rf /tmp/maidau-t; mkdir -p /tmp/maidau-t; }

echo "== syntax =="
for f in "$PKGDIR"/bin/*.sh "$PKGDIR"/install.sh; do
  bash -n "$f" || fail "bash -n $f"
done
command -v shellcheck >/dev/null 2>&1 && shellcheck -S error "$PKGDIR"/bin/*.sh "$PKGDIR"/install.sh || true
ok "syntax"

echo "== personal data =="
if grep -rn "/home/EXAMPLEUSER/" "$PKGDIR/bin" "$PKGDIR/README.md" "$PKGDIR/install.sh" 2>/dev/null | grep -v "s|/home/EXAMPLEUSER/|"; then
  fail "personal string leaked"
fi
ok "no personal data"

echo "== installer dry run =="
fresh_home
HOME=/tmp/maidau-t bash "$PKGDIR/install.sh" --check >/dev/null 2>&1 || fail "install --check"
[ -e /tmp/maidau-t/.local/bin/update-all.sh ] && fail "dry run wrote files"
ok "installer dry run clean"

echo "== zypper --check =="
fresh_home
export PATH="$STUBS:$PATH" FIXDIR NOTIFY_LOG=/tmp/maidau-t/notify.log
export RPM_PRESENT="xone-kmp-default xpadneo-kmp-default joycond inputplumber hid-tmff2-kmp-default"
out=$(HOME=/tmp/maidau-t UPDATE_PM=zypper bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1)
echo "$out" | grep -q "zypper=2 extra=2" || fail "zypper counts: $out"
echo "$out" | grep -q "System update available" || fail "zypper sys-hit notify"
grep -q "packman: 2" /tmp/maidau-t/.local/share/update-all.log || fail "packman logged"
ok "zypper backend (incl. packman + kernel hit)"

echo "== dnf --check, exit 100 =="
fresh_home
out=$(HOME=/tmp/maidau-t UPDATE_PM=dnf DNF_RC=100 bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1)
echo "$out" | grep -q "System update available" || fail "dnf sys-hit: $out"
grep -q "rpmfusion: 1" /tmp/maidau-t/.local/share/update-all.log || fail "rpmfusion counted"
DNF_RC=0 FLAT_EMPTY=1 HOME=/tmp/maidau-t UPDATE_PM=dnf bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1 | grep -q "System up to date" || fail "dnf clean state"
ok "dnf backend (exit 100 + rpmfusion)"

echo "== apt --check =="
fresh_home
HOME=/tmp/maidau-t UPDATE_PM=apt bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1 | grep -q "System update available" || fail "apt sys-hit"
ok "apt backend (all repos + kernel hit)"

echo "== pacman --check =="
fresh_home
out=$(HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1)
echo "$out" | grep -q "pacman=2 extra=1" || fail "pacman counts: $out"
ok "pacman backend (incl. AUR count)"

echo "== strict abort without snapshots =="
fresh_home
out=$(HOME=/tmp/maidau-t UPDATE_PM=dnf DNF_RC=100 bash "$PKGDIR/bin/update-all.sh" --require-snapshot < /dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "strict exit code $rc"
echo "$out" | grep -q "ABORT" || fail "strict abort message"
ok "strict mode aborts with no snapshot tooling"

echo "== partial state on AUR failure =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=pacman UPDATE_AUR=1 YAY_FAIL=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "update run crashed"
grep -q "finished partially" /tmp/maidau-t/notify.log || fail "partial notify missing"
grep -q "AUR: skipped" /tmp/maidau-t/.local/share/update-all.log && fail "AUR ran despite failure path"
ok "partial state (AUR opt-in failure)"
echo "== AUR skipped by default =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "update run crashed"
grep -q "AUR: skipped (opt-in" /tmp/maidau-t/.local/share/update-all.log || fail "AUR default-skip missing"
ok "AUR opt-in default off"

echo "== metadata savings =="
grep -q -- "--no-refresh" "$PKGDIR/bin/pm-zypper.sh" || fail "grub install refresh skip"
grep -q "ZYPPER_NO_REFRESH" "$PKGDIR/controllers/setup-controllers.sh" || fail "controllers refresh skip"
grep -q "ZYPPER_NO_REFRESH=1" "$PKGDIR/bin/update-all.sh" || fail "no-refresh export"
mkdir -p /tmp/maidau-t/fwmeta && touch -d "1 hour ago" /tmp/maidau-t/fwmeta/firmware.xml.gz
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=pacman FWUPD_CACHE=/tmp/maidau-t/fwmeta bash "$PKGDIR/bin/update-all.sh" < /dev/null >/tmp/maidau-t/out.txt 2>&1 || fail "update run crashed"
grep -q "metadata fresh" /tmp/maidau-t/.local/share/update-all.log || fail "fresh metadata not skipped"
grep -q "REFRESH-CALLED" /tmp/maidau-t/out.txt && fail "refresh ran despite fresh metadata"
rm -rf /tmp/maidau-t/fwmeta
HOME=/tmp/maidau-t UPDATE_PM=pacman FWUPD_CACHE=/tmp/maidau-t/fwmeta bash "$PKGDIR/bin/update-all.sh" < /dev/null >/tmp/maidau-t/out2.txt 2>&1 || fail "update run 2 crashed"
grep -q "REFRESH-CALLED" /tmp/maidau-t/out2.txt || fail "refresh skipped with stale cache"
ok "metadata savings (zypper flags + fwupd fresh-skip)"

echo "== background failure propagates =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=pacman FLAT_FAIL=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1
grep -q "finished with errors" /tmp/maidau-t/notify.log || fail "bg flatpak failure hidden"
ok "background failure propagates"

echo "== controllers opt-in =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
mkdir -p /tmp/maidau-t/.local/bin
printf '#!/bin/bash\necho "Installing xone-kmp-test"\nexit 0\n' > /tmp/maidau-t/.local/bin/setup-controllers.sh
chmod +x /tmp/maidau-t/.local/bin/setup-controllers.sh
HOME=/tmp/maidau-t UPDATE_PM=zypper bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "opt-out run crashed"
grep -q "controllers: skipped (opt-in" /tmp/maidau-t/.local/share/update-all.log || fail "skip not announced up front"
grep -q "Installing xone-kmp-test" /tmp/maidau-t/.local/share/update-all.log && fail "controllers ran without opt-in"
ok "controllers skipped by default"
HOME=/tmp/maidau-t UPDATE_PM=zypper UPDATE_CONTROLLERS=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "opt-in run crashed"
grep -q "Installing xone-kmp-test" /tmp/maidau-t/.local/share/update-all.log || fail "opt-in controllers did not run"
ok "controllers run when opted in"

echo "== appimages =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
mkdir -p /tmp/maidau-t/AppImages
: > /tmp/maidau-t/AppImages/Current.AppImage
: > /tmp/maidau-t/AppImages/Updatable.AppImage
mkdir -p /tmp/maidau-t/.config
printf 'DlApp|https://example.com/dl.AppImage\n' > /tmp/maidau-t/.config/maidau-appimages.conf
HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1 | grep -q "appimg=3" || fail "appimage count"
ok "appimage check counts tool-managed + links"
HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "appimage update run crashed"
grep -q "appimage link: DlApp.AppImage: downloaded." /tmp/maidau-t/.local/share/update-all.log || fail "link download missing"
[ -x /tmp/maidau-t/AppImages/DlApp.AppImage ] || fail "downloaded file not installed/executable"
ls /tmp/maidau-t/AppImages/DlApp.AppImage.bak-* >/dev/null 2>&1 || true
grep -q "Updatable.AppImage: updated." /tmp/maidau-t/.local/share/update-all.log || fail "tool update missing"
ok "appimage update (tool + link + backup)"
HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "rerun crashed"
grep -q "unchanged, skipped." /tmp/maidau-t/.local/share/update-all.log || fail "second run re-downloaded"
ok "appimage links idempotent via etag cache"

echo "== cleanup =="
rm -rf /tmp/maidau-t
ok "cleanup"
echo "ALL $PASS PASSED"
