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
  `tests:`, `chore:`), one logical change each. Sign off every commit
  (`git commit -s`). Bug fixes cite `Fixes: #N`.
- Destructive actions stay opt-in (`UPDATE_AUR`, `UPDATE_CONTROLLERS`,
  passwordless sudo). `--check` reports, changes nothing.
- Never hold packages; snapshots before upgrades (documented honestly).

## Verify

- `bash tests/run.sh` - stub farm fakes package managers, safe anywhere
- `bash install.sh --check` - dry run
- Uninstaller contract: `--uninstall` keeps settings (asks), `--purge`
  removes everything. Test both with a fake HOME, never the live one.

Before finishing: pass docs/REVIEW.md.
