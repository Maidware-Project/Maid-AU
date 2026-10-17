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
# keep every test off the network; the maid suite section turns the
# suite back on against a local fixture origin.
export MAID_SUITE=0

echo "== syntax =="
for f in "$PKGDIR"/bin/*.sh "$PKGDIR"/install.sh; do
  bash -n "$f" || fail "bash -n $f"
done
command -v shellcheck >/dev/null 2>&1 && shellcheck -S error "$PKGDIR"/bin/*.sh "$PKGDIR"/install.sh || true
ok "syntax"

echo "== personal data =="
if grep -rn --exclude-dir=__pycache__ -iE "AA:BB|RemoteApp|ExampleBuds|Liberty|example-host|10\.0\.0|/(home|Users)/[^/[:space:]]+" \
    "$PKGDIR/bin" "$PKGDIR/desktop" "$PKGDIR/README.md" "$PKGDIR/install.sh" 2>/dev/null; then
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

echo "== snapshot safety net =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=pacman SNAP_OK=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "snapshot run crashed"
grep -q "safety: snapshots #42 -> #41" /tmp/maidau-t/.local/share/update-all.log || fail "snapshot pair not logged"
grep -q "Snaps: snapshots #42 -> #41" /tmp/maidau-t/notify.log || fail "snapshot numbers not notified"
ok "snapshots taken + numbers reported (SNAP_OK stub)"

fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
out=$(HOME=/tmp/maidau-t UPDATE_PM=pacman SNAP_LIST_ONLY=1 bash "$PKGDIR/bin/update-all.sh" --require-snapshot < /dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "snapshot-fail strict exit $rc"
echo "$out" | grep -q "ABORT: --require-snapshot and pre-snapshot failed." || fail "strict creation-fail abort"
ok "strict mode aborts when snapshot creation fails"

fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=pacman SNAP_LIST_ONLY=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "non-strict snapshot-fail run crashed"
grep -q "safety: pre-update snapshot FAILED - continuing without rollback" /tmp/maidau-t/.local/share/update-all.log || fail "loud non-strict warning missing"
ok "snapshot failure continues by default, logged loudly"

fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
out=$(HOME=/tmp/maidau-t UPDATE_PM=zypper SNAP_EMPTY=1 RPM_PRESENT="xone-kmp-default" bash "$PKGDIR/bin/update-all.sh" --require-snapshot < /dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "zypper strict no-readout exit $rc"
echo "$out" | grep -q "ABORT: --require-snapshot and no snapshot before the upgrade." || fail "zypper strict abort missing"
ok "strict mode aborts on zypper without a pre-update snapshot"

fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=zypper SNAP_EMPTY=1 RPM_PRESENT="xone-kmp-default" bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "zypper no-readout run crashed"
grep -q "safety: no snapshot before the upgrade - continuing without rollback" /tmp/maidau-t/.local/share/update-all.log || fail "zypper loud warning missing"
ok "zypper continues without snapshot by default, logged loudly"

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
# integrity: https-only, pinned hash enforced, malformed refused
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
mkdir -p /tmp/maidau-t/AppImages /tmp/maidau-t/.config
goodsha=$(printf 'fake-new-binary\n' | sha256sum | awk '{print $1}')
printf 'PinOk|https://example.com/ok.AppImage|%s\nPinBad|https://example.com/bad.AppImage|0000000000000000000000000000000000000000000000000000000000000000\nPlain|http://example.com/x.AppImage\nPinMal|https://example.com/m.AppImage|zzz\n' "$goodsha" > /tmp/maidau-t/.config/maidau-appimages.conf
HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "integrity run crashed"
grep -q "appimage link: PinOk.AppImage: downloaded." /tmp/maidau-t/.local/share/update-all.log || fail "pinned-good not installed"
[ -x /tmp/maidau-t/AppImages/PinOk.AppImage ] || fail "pinned-good not executable"
grep -q "PinBad.AppImage: HASH MISMATCH" /tmp/maidau-t/.local/share/update-all.log || fail "hash mismatch not logged"
[ -e /tmp/maidau-t/AppImages/PinBad.AppImage ] && fail "bad-hash file installed!"
grep -q "Plain: refused (not https)" /tmp/maidau-t/.local/share/update-all.log || fail "http not refused"
[ -e /tmp/maidau-t/AppImages/x.AppImage ] && fail "plaintext file installed!"
grep -q "PinMal: bad pinned hash" /tmp/maidau-t/.local/share/update-all.log || fail "malformed pin not rejected"
[ -e /tmp/maidau-t/AppImages/m.AppImage ] && fail "malformed-pin file installed!"
ok "appimage integrity: https-only, hash enforced"
rm -rf /tmp/maidau-t

echo "== maid suite =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log MAID_SUITE=1
mkdir -p "/tmp/maidau-t/Documents/GitHub"
git init -q --bare /tmp/maidau-origin.git
git clone -q /tmp/maidau-origin.git "/tmp/maidau-t/Documents/GitHub/Maid BT" 2>/dev/null
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" config user.email t@t.t
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" config user.name t
printf '#!/bin/bash\necho deployed >> "$HOME/maidau-deploy-marker"\n' > "/tmp/maidau-t/Documents/GitHub/Maid BT/install.sh"
chmod +x "/tmp/maidau-t/Documents/GitHub/Maid BT/install.sh"
echo hi > "/tmp/maidau-t/Documents/GitHub/Maid BT/f"
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" add f install.sh
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" commit -qm one
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" push -q origin master 2>/dev/null || git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" push -q origin main 2>/dev/null || true
echo hi2 > "/tmp/maidau-t/Documents/GitHub/Maid BT/f2"
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" add f2
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" commit -qm two
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" push -q 2>/dev/null || true
git -C "/tmp/maidau-t/Documents/GitHub/Maid BT" reset -q --hard HEAD~1
# point the suite at the local fixture origin instead of github
export MAID_SUITE_LIST='Maid BT|/tmp/maidau-origin.git'
HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1 | grep -q "maid=1" || fail "behind repo not counted"
grep -q "1 commit(s) behind" /tmp/maidau-t/.local/share/update-all.log || fail "behind not logged"
ok "maid suite behind-counted in check"
MAID_SUITE=0 HOME=/tmp/maidau-t UPDATE_PM=pacman bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1 | grep -q "maid=0" || fail "opt-out count wrong"
grep -q "skipped (MAID_SUITE=0)" /tmp/maidau-t/.local/share/update-all.log || fail "opt-out not logged"
ok "maid suite opt-out"
HOME=/tmp/maidau-t UPDATE_PM=pacman UPDATE_MAID_DEPLOY=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "deploy run crashed"
grep -q "Maid BT.*updated (1)" /tmp/maidau-t/.local/share/update-all.log || fail "pull not logged"
grep -q "maid suite:   [0-9a-f]* two" /tmp/maidau-t/.local/share/update-all.log || fail "incoming commit not shown"
grep -q "maid suite:   files: " /tmp/maidau-t/.local/share/update-all.log || fail "changed files not shown"
grep -q "UPDATE_MAID_DEPLOY=1 - rerunning install.sh" /tmp/maidau-t/.local/share/update-all.log || fail "deploy intent not logged"
grep -q "Maid BT.*redeployed" /tmp/maidau-t/.local/share/update-all.log || fail "deploy not logged"
grep -q "deployed" /tmp/maidau-t/maidau-deploy-marker || fail "fixture installer did not run"
ok "maid suite pull + redeploy with UPDATE_MAID_DEPLOY=1"
rm -rf /tmp/maidau-origin.git

# a suite repo that is not on disk is cloned from its github url
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log MAID_SUITE=1
mkdir -p /tmp/maidau-clone
git init -q --bare /tmp/maidau-clone/Maid-Helper.git
git clone -q /tmp/maidau-clone/Maid-Helper.git /tmp/maidau-seed 2>/dev/null
git -C /tmp/maidau-seed config user.email t@t.t
git -C /tmp/maidau-seed config user.name t
printf '#!/bin/bash\necho deployed >> "$HOME/maidau-clone-marker"\n' > /tmp/maidau-seed/install.sh
chmod +x /tmp/maidau-seed/install.sh
echo hi > /tmp/maidau-seed/f
git -C /tmp/maidau-seed add f install.sh
git -C /tmp/maidau-seed commit -qm one
git -C /tmp/maidau-seed push -q origin HEAD 2>/dev/null || true
export MAID_SUITE_LIST='Maid Helper|/tmp/maidau-clone/Maid-Helper.git'
XDG_DATA_HOME= HOME=/tmp/maidau-t UPDATE_PM=pacman UPDATE_MAID_DEPLOY=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "clone run crashed"
grep -q "Maid Helper: cloned from github" /tmp/maidau-t/.local/share/update-all.log || fail "clone not logged"
[ -d "/tmp/maidau-t/.local/share/maid-au/suite/Maid-Helper/.git" ] || fail "repo not cloned into managed dir"
grep -q "deployed" /tmp/maidau-t/maidau-clone-marker || fail "cloned repo not deployed"
ok "maid suite clones a missing repo from github"
rm -rf /tmp/maidau-clone /tmp/maidau-seed

export MAID_SUITE=0; unset MAID_SUITE_LIST
rm -rf /tmp/maidau-t

echo "== controllers via helper (non-suse) =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
mkdir -p /tmp/maidau-t/.local/bin
printf '#!/bin/bash\necho "helper gamepads: $1"\n[ "$1" = "check" ] && exit 2\nexit 0\n' > /tmp/maidau-t/.local/bin/mod-gamepad.sh
chmod +x /tmp/maidau-t/.local/bin/mod-gamepad.sh
HOME=/tmp/maidau-t UPDATE_PM=pacman UPDATE_CONTROLLERS=1 bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1 | grep -q "helper gamepads: check" || fail "helper not driven in check"
grep -q "helper reports issues" /tmp/maidau-t/.local/share/update-all.log || fail "helper issue not logged"
ok "controllers delegated to helper in check"
HOME=/tmp/maidau-t UPDATE_PM=pacman UPDATE_CONTROLLERS=1 bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "helper update run crashed"
grep -q "controllers: helper run ok" /tmp/maidau-t/.local/share/update-all.log || fail "helper run not logged"
ok "controllers delegated to helper in update"
rm -rf /tmp/maidau-t

echo "== cleanup =="
rm -rf /tmp/maidau-t
ok "cleanup"
echo "ALL $PASS PASSED"
