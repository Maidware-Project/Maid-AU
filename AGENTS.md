# AGENTS.md — Maid AU (for AI assistants; humans see README.md)

One maintainer plus friends helping out — keep every change small,
reviewable, and justified. No drive-by refactors, no new dependencies
without asking.

People over AI, always: this project is human-built and human-reviewed.
AI assists, humans decide. Write code, messages, and docs a person can
follow with no assistant involved — clear names, plain language, no
cleverness. The goal is users who understand their system, not users
dependent on one.

On-demand system updater (flatpak + native + firmware). No services.

## Layout

- `bin/update-all.sh` core, `bin/pm-*.sh` distro backends (auto-detected
  from `/etc/os-release`, override `UPDATE_PM=...`), `bin/system-updater`
- `controllers/` openSUSE-only KMP stack, `desktop/` launcher
- `install.sh` multi-distro installer, `tests/` suite + fixtures + stubs

## Rules

- No personal data in repo. Installer copies, never symlinks, backs up.
- Destructive actions stay opt-in (`UPDATE_AUR`, `UPDATE_CONTROLLERS`,
  passwordless sudo). `--check` reports, changes nothing.
- Never hold packages; snapshots before upgrades (documented honestly).

## Verify

- `bash tests/run.sh` — stub farm fakes package managers, safe anywhere
- `bash install.sh --check` — dry run
- Uninstaller contract: `--uninstall` keeps settings (asks), `--purge`
  removes everything. Test both with a fake HOME, never the live one.
