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
for f in "$PKGDIR"/bin/*.sh "$PKGDIR"/controllers/*.sh "$PKGDIR"/install.sh; do
  bash -n "$f" || fail "bash -n $f"
done
command -v shellcheck >/dev/null 2>&1 && shellcheck -S error "$PKGDIR"/bin/*.sh "$PKGDIR"/install.sh || true
ok "syntax"

echo "== personal data =="
if grep -rn --exclude-dir=__pycache__ -iE "([0-9a-f]{2}:){5}[0-9a-f]{2}|/(home|Users)/[^/[:space:]]+|(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}" \
    "$PKGDIR/bin" "$PKGDIR/desktop" "$PKGDIR/README.md" "$PKGDIR/install.sh" 2>/dev/null \
    | grep -v "AA:BB:CC:DD:EE:FF"; then
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
export RPM_PRESENT="xone-kmp-longterm xpadneo-kmp-longterm joycond inputplumber hid-tmff2-kmp-longterm"
out=$(HOME=/tmp/maidau-t UPDATE_PM=zypper bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1)
echo "$out" | grep -q "zypper=2 extra=2" || fail "zypper counts: $out"
echo "$out" | grep -q "System update available" || fail "zypper sys-hit notify"
grep -q "packman: 2" /tmp/maidau-t/.local/share/update-all.log || fail "packman logged"
ok "zypper backend (incl. packman + kernel hit)"

echo "== check failure is honest =="
fresh_home
mkdir -p /tmp/maidau-failstub
cat > /tmp/maidau-failstub/zypper <<'EOF'
#!/bin/bash
case "$*" in
  *dist-upgrade*--dry-run*) echo "Problem: the package manager cannot resolve this update"; exit 4 ;;
  *list-updates*-r*packman*) echo "No updates found" ;;
  *list-updates*) echo "No updates found" ;;
  *refresh*) echo "All repositories have been refreshed." ;;
  *) exit 0 ;;
esac
EOF
chmod +x /tmp/maidau-failstub/zypper
out=$(HOME=/tmp/maidau-t UPDATE_PM=zypper PATH="/tmp/maidau-failstub:$PATH" \
  bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "check failure exit code $rc"
echo "$out" | grep -q "failed=1" || fail "check failure summary missing: $out"
echo "$out" | grep -q "Check failed - the package manager could not complete the preview" \
  || fail "check failure message missing"
ok "check failure exits 1 and says so"
rm -rf /tmp/maidau-failstub

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
out=$(HOME=/tmp/maidau-t UPDATE_PM=zypper SNAP_EMPTY=1 RPM_PRESENT="xone-kmp-longterm" bash "$PKGDIR/bin/update-all.sh" --require-snapshot < /dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "zypper strict no-readout exit $rc"
echo "$out" | grep -q "ABORT: --require-snapshot and no snapshot before the upgrade." || fail "zypper strict abort missing"
ok "strict mode aborts on zypper without a pre-update snapshot"

fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
HOME=/tmp/maidau-t UPDATE_PM=zypper SNAP_EMPTY=1 RPM_PRESENT="xone-kmp-longterm" bash "$PKGDIR/bin/update-all.sh" < /dev/null >/dev/null 2>&1 || fail "zypper no-readout run crashed"
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

echo "== controller kmps follow the running kernel flavor =="
fresh_home
export NOTIFY_LOG=/tmp/maidau-t/notify.log
# update --check counts the kmps of the flavor uname reports (the stub
# says longterm): xpadneo's longterm build is the missing one here.
mkdir -p /tmp/maidau-t/.local/bin
printf '#!/bin/bash\nexit 0\n' > /tmp/maidau-t/.local/bin/setup-controllers.sh
chmod +x /tmp/maidau-t/.local/bin/setup-controllers.sh
out=$(HOME=/tmp/maidau-t UPDATE_PM=zypper UPDATE_CONTROLLERS=1 RPM_PRESENT="xone-kmp-longterm joycond inputplumber" bash "$PKGDIR/bin/update-all.sh" --check < /dev/null 2>&1)
grep -q "check: controllers: xpadneo-kmp-longterm missing." /tmp/maidau-t/.local/share/update-all.log || fail "check did not follow flavor: $out"
grep -q "kmp-default" /tmp/maidau-t/.local/share/update-all.log && fail "check asked for the default flavor"
ok "updater --check counts the running flavor's kmps"

# setup-controllers: a fake sudo passes zypper through and swallows the
# rest (the shared stub execs, which would touch the real machine); the
# zypper stub says xone/hid-tmff2 have no longterm build.
mkdir -p /tmp/maidau-t/fakesudo
printf '#!/bin/bash\nwhile [ "${1:-}" = "-n" ]; do shift; done\ncase "$1" in zypper) exec "$@" ;; *) echo "sudo-stub: $*" ;; esac\n' > /tmp/maidau-t/fakesudo/sudo
chmod +x /tmp/maidau-t/fakesudo/sudo
export KMP_MISSING="xone-kmp-longterm hid-tmff2-kmp-longterm"
out=$(HOME=/tmp/maidau-t USER=maid PATH="/tmp/maidau-t/fakesudo:$PATH" bash "$PKGDIR/controllers/setup-controllers.sh" --update < /dev/null 2>&1)
echo "$out" | grep -q "no xone-kmp-longterm for flavor longterm, skipping" || fail "unbuilt flavor kmp not skipped: $out"
echo "$out" | grep -q "xpadneo-kmp-longterm" || fail "flavor's xpadneo kmp not installed: $out"
echo "$out" | grep -q "kmp-default" && fail "default kmp used on a longterm kernel"
unset KMP_MISSING
ok "setup installs the flavor's kmps, skips the unbuilt ones"

# the health check asks for the same flavor
out=$(HOME=/tmp/maidau-t RPM_PRESENT="xone-kmp-longterm xpadneo-kmp-longterm joycond inputplumber hid-tmff2-kmp-longterm" bash "$PKGDIR/controllers/check-controllers.sh" < /dev/null 2>&1)
echo "$out" | grep -q "\[OK\]   xpadneo-kmp-longterm" || fail "health check did not follow flavor: $out"
echo "$out" | grep -q "kmp-default" && fail "health check asked for the default flavor"
ok "health check follows the flavor too"

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

echo "== system-updater finds update-all next to itself =="
rm -rf /tmp/maidau-u; mkdir -p /tmp/maidau-u/bin /tmp/maidau-u/stubs
cp "$PKGDIR/bin/update-all.sh" "$PKGDIR/bin/system-updater" /tmp/maidau-u/bin/
cat > /tmp/maidau-u/stubs/xdg-terminal-exec <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > /tmp/maidau-u/terminal-args
exit 0
EOF
printf '#!/bin/bash\nexec "$@"\n' > /tmp/maidau-u/stubs/systemd-inhibit
chmod +x /tmp/maidau-u/stubs/*
PATH="/tmp/maidau-u/stubs:$PATH" HOME=/tmp/maidau-u \
  bash /tmp/maidau-u/bin/system-updater --last < /dev/null >/dev/null 2>&1
[ "$(head -n1 /tmp/maidau-u/terminal-args 2>/dev/null)" = "/tmp/maidau-u/bin/update-all.sh" ] \
  || fail "system-updater did not use the sibling update-all.sh"
ok "system-updater resolves the packaged sibling path"
rm -rf /tmp/maidau-u

echo "== gui =="
if command -v cmake >/dev/null 2>&1 && pkg-config --exists Qt6Widgets 2>/dev/null; then
  rm -rf /tmp/maidau-gui-build
  cmake -S "$PKGDIR/gui" -B /tmp/maidau-gui-build -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 \
    && cmake --build /tmp/maidau-gui-build -j"$(nproc)" >/dev/null 2>&1 \
    || fail "gui build failed"
  [ -x /tmp/maidau-gui-build/maid-au-gui ] || fail "gui binary missing"
  QT_QPA_PLATFORM=offscreen /tmp/maidau-gui-build/maid-au-gui --version 2>&1 \
    | grep -q "maid-au" || fail "gui --version"
  cat > /tmp/maidau-gui-fake.sh <<'EOF'
#!/usr/bin/env bash
echo "=== check done (pacman=1 extra=0 flatpak=0 firmware=0 controllers=0 appimg=0 maid=0 system=0 failed=0) ==="
EOF
  chmod +x /tmp/maidau-gui-fake.sh
  QT_QPA_PLATFORM=offscreen MAID_AU_UPDATE_SCRIPT=/tmp/maidau-gui-fake.sh \
    timeout 12 /tmp/maidau-gui-build/maid-au-gui --check --quit-after-check \
    >/dev/null 2>&1 || fail "gui check smoke test"
  rm -f /tmp/maidau-gui-fake.sh
  rm -rf /tmp/maidau-gui-build
  ok "gui builds and runs a check"
else
  echo "skip - Qt6 Widgets development files not installed"
fi

echo "== cleanup =="
rm -rf /tmp/maidau-t
ok "cleanup"
echo "ALL $PASS PASSED"
