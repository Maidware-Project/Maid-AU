# changelog

## appimages

- `~/AppImages` / `~/Applications` `*.AppImage` files update through
  embedded info when `appimageupdatetool` exists, plus user direct links
  (`~/.config/maidau-appimages.conf`, `Name|URL` per line) that only
  download on change (etag cache) with backup-before-replace. failures
  mark the run partial, never failed.

## controllers are opt-in

- the Bazzite KMP stack no longer runs by itself: `UPDATE_CONTROLLERS=1`
  to include it, and the updater announces the skip up front before
  anything changes. don't want controller stuff at all? just never opt
  in — nothing installs, nothing breaks.

## faster runs: stop re-downloading metadata

- zypper backend refreshes once; later installs in the same run pass
  `--no-refresh` (grub plugin ensure, controller installs via
  `ZYPPER_NO_REFRESH`). was 3-4 metadata downloads per run.
- fwupd skips its refresh when metadata is fresher than 24h
  (override: `FWUPD_CACHE`). still always checks for actual updates.
- what still takes time is downloads + installs themselves — that part
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
