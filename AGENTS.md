# AGENTS.md — Maid AU (for AI assistants; humans see README.md)

One maintainer plus friends helping out — keep every change small,
reviewable, and justified. No drive-by refactors, no new dependencies
without asking.

Honesty is non-negotiable: say what you actually did versus what you
were asked to do. Never claim a test ran, a build passed, or hardware
was verified unless it truly happened in this session. Report failures
and shortcuts plainly, mark uncertainty as uncertainty, and never hide
a skipped step behind vague wording.

People over AI, always: this project is human-built and human-reviewed.
AI assists, humans decide. Write code, messages, and docs a person can
follow with no assistant involved — clear names, plain language, no
cleverness. The goal is users who understand their system, not users
dependent on one.

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
  (`git commit -s`); AI-assisted work adds an `Assisted-by:` trailer
  naming the tool. Bug fixes cite `Fixes: #N`.
- Destructive actions stay opt-in (`UPDATE_AUR`, `UPDATE_CONTROLLERS`,
  passwordless sudo). `--check` reports, changes nothing.
- Never hold packages; snapshots before upgrades (documented honestly).

## Verify

- `bash tests/run.sh` — stub farm fakes package managers, safe anywhere
- `bash install.sh --check` — dry run
- Uninstaller contract: `--uninstall` keeps settings (asks), `--purge`
  removes everything. Test both with a fake HOME, never the live one.

Before finishing: pass docs/REVIEW.md.
