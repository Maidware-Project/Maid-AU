# changelog

## snapshot honesty + maid suite visibility

- a failed pre-update snapshot is now said loudly (console + log) on
  pacman, dnf and apt instead of continuing silently, and zypper got
  the strict `--require-snapshot` check the others already had: no
  snapshot before the upgrade now aborts when the flag is set, and
  says so loudly when it is not.
- maid suite pulls list the incoming commits and changed files in the
  log, and `UPDATE_MAID_DEPLOY=1` states it is rerunning installers on
  exactly those commits.

## controllers via helper off-suse

- non-openSUSE distros drive Maid Helper's gamepad doctor when it is
  installed (same `UPDATE_CONTROLLERS=1` opt-in, same logging); without
  Helper the old guidance stands.

## appimage integrity

- direct links (`Name|URL`) fetch https-only now (plaintext refused,
  redirects can't downgrade via `--proto '=https'`); optional third
  field pins the expected SHA-256 (`Name|URL|SHA256`), verified before
  anything is replaced - mismatch or malformed pin leaves the old
  file alone and marks the run partial.

## installer + updater fixes

- backups only on real change: the compare now runs against the
  rewritten file content, so reinstalls no longer pile up
  `.bak-<timestamp>` copies of the desktop file.
- install and `--uninstall` both honor `--prefix`/`DESTDIR` (program
  files use the same `BINDIR`/`SHAREDIR` either way).
- controller zypper log uses `mktemp` instead of a fixed `/tmp` path.
- `--require-snapshot` flag parsing keeps arguments intact (array,
  no word-splitting rebuild).

## maid suite awareness

- the updater knows its own family (Maid BT, Maidshare, watcher,
  Maid Helper, Maid Runner): `--check` reports behind checkouts,
  full runs pull `--ff-only`, diverged trees are left alone and flagged.
  `UPDATE_MAID_DEPLOY=1` also reruns each installer; default only pulls
  code and tells you to deploy. `MAID_SUITE=0` opts out entirely.

## appimages

- `~/AppImages` / `~/Applications` `*.AppImage` files update through
  embedded info when `appimageupdatetool` exists, plus user direct links
  (`~/.config/maidau-appimages.conf`, `Name|URL` per line) that only
  download on change (etag cache) with backup-before-replace. failures
  mark the run partial, never failed.

## controllers are opt-in

- Bazzite KMP stack only runs with `UPDATE_CONTROLLERS=1`. don't want
  it? just never opt in.

## faster runs: stop re-downloading metadata

- zypper backend refreshes once; later installs in the same run pass
  `--no-refresh` (grub plugin ensure, controller installs via
  `ZYPPER_NO_REFRESH`). was 3-4 metadata downloads per run.
- fwupd skips its refresh when metadata is fresher than 24h
  (override: `FWUPD_CACHE`). still always checks for actual updates.
- what still takes time is downloads + installs themselves - that part
  is the distro's work, no script can skip it.

## snapshot honesty + failure policy

- snapshots are best-effort by default and say so; `--require-snapshot`
  aborts the upgrade when no snapshot tooling works.
- new PARTIAL state: failed AUR builds (opt-in via `UPDATE_AUR=1`, was
  always-on before) report partial instead of hiding.
- reboot hints use authoritative signals where they exist
  (`/var/run/reboot-required` on apt, `needs-restarting -r` on dnf,
  staged kernel vs boot time on pacman), name patterns only as backup.
- zypper dup documents why `--allow-vendor-change` is there.
- sudoers guidance rewritten: risk stated plainly, validate-then-install
  flow (`visudo -c -f` first, mode 0440).
- arch installs with full `-Syu` (partial upgrades unsupported).
- log keeps 1000 lines; controllers wording fixed (health check never
  fails the run, failed updates do).
- tests/: fixture-driven suite covers all four backends, strict abort,
  partial state (11 checks, runs in CI).
