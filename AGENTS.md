# AGENTS.md - Maid AU (for AI assistants; humans see README.md)

One maintainer plus a few friends helping out. Keep changes small enough
to review, skip refactors nobody asked for, and ask before adding a
dependency. Anything that touches packages, snapshots or sudo is the part
to slow down on.

Say what you actually did, not what you were asked to do. The stub farm
makes the suite cheap to run, so there is no reason to claim a green run
you didn't do.

The assistant helps, a person decides. These scripts run as root on other
people's machines, so a human has to understand every line before it ships.

On-demand system updater (flatpak + native + firmware). No services.
Lowercase terse voice in docs (README, messages, notifications).

## What you can't do here

- These scripts run as root and do real package operations. The stub farm
  fakes the package managers, so the suite proves the logic, not that an
  upgrade works on a real system.
- Snapshot and controller paths are distro-specific (the `controllers/`
  stack is openSUSE-only) and need that distro to mean anything.
- Without root, the privileged paths cannot be exercised at all.

## Layout

- `bin/update-all.sh` core, `bin/pm-*.sh` distro backends (auto-detected
  from `/etc/os-release`, override `UPDATE_PM=...`), `bin/system-updater`
- `controllers/` openSUSE-only KMP stack, `desktop/` launcher
- `install.sh` multi-distro installer, `tests/` suite + fixtures + stubs

## Rules

- No personal data in repo. Installer copies, never symlinks, backs up.
- CODE_OF_CONDUCT.md applies to code, comments, and docs:
  technical scope, no politics, stay neutral.
- Commits: short lowercase summaries with a prefix (`fix:`, `feat:`, `docs:`,
  `tests:`, `chore:`), one logical change each. Sign off every commit -
  the trailer is exactly `Signed-off-by: visa`, no email. Bug fixes cite
  `Fixes: #N`.
- Destructive actions stay opt-in (`UPDATE_AUR`, `UPDATE_CONTROLLERS`,
  passwordless sudo). `--check` reports, changes nothing.
- Never hold packages; snapshots before upgrades (documented honestly).

## Never

- Never push. The maintainer pushes; commits stay local until asked.
- Never make a destructive action automatic, and never turn one on by
  default.
- Never hold packages, and never claim a snapshot or a firmware step
  happened when it did not.
- Never report a green run, or a system you did not touch, that you did
  not actually verify.

## Boundaries (do not touch)

- `--check` reports and changes nothing; the run is the only path that
  touches the system.
- The backend pattern: `bin/pm-*.sh`, auto-detected from `/etc/os-release`,
  overridable with `UPDATE_PM=...`.
- The installer contract: copies, never symlinks, backs up; `--uninstall`
  keeps settings (asks), `--purge` removes everything.

## Verify

- `bash tests/run.sh` - stub farm fakes package managers, safe anywhere
- `bash install.sh --check` - dry run
- Uninstaller contract: `--uninstall` keeps settings (asks), `--purge`
  removes everything. Test both with a fake HOME, never the live one.

## Making a change

1. `git status -sb` first. A commit or a sync can land while you work,
   and amending something already pushed leaves duplicate commits.
2. Make the smallest diff that solves the stated problem.
3. Run `bash tests/run.sh` and `bash install.sh --check`.
4. If it touches packages, snapshots or sudo, say exactly what you could
   not test here.
5. Pass `docs/REVIEW.md`, then commit with a sign-off. Do not push.

## References

- `README.md` - what it does, supported distros, updater options
- `docs/REVIEW.md` - the checklist to pass before a change ships
- `CONTRIBUTING.md` - how to take part
- `CODE_OF_CONDUCT.md` - scope, and what stays out of the repo
- `CHANGELOG.md` - what changed, release by release
- `SECURITY.md` - how to report a security problem
