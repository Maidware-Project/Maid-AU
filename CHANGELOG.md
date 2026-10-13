# changelog

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
