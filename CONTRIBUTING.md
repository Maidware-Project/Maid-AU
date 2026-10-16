# contributing

small, reviewable changes only - one logical change per pull request. if
it needs a paragraph to explain, it's two changes. read AGENTS.md first;
it applies to humans and AI assistants alike. maintained by Maidware
Project.

## commits

- short lowercase summaries with a prefix: `fix:`, `feat:`, `docs:`,
  `tests:`, `chore:` - e.g. `fix: print PARTIAL when only the flatpak
  layer fails`
- sign off every commit (`git commit -s` appends it):
  `Signed-off-by: Your Name <you@example.com>` - the developer's
  certificate of origin, your word that you may contribute it
- bug fixes name what they fix: `Fixes: #123` or `Closes: #123`

## before opening anything

- `bash tests/run.sh` green, output pasted in the pull request. the stub
  farm fakes pacman, apt, dnf and zypper, so the whole thing runs anywhere
  without touching a real system: --check counts, strict abort without
  snapshots, PARTIAL on an AUR failure, appimage hash pinning, and the
  maid suite handoff.
- `bash install.sh --check` writes nothing
- CI must be green before review - a green run on your machine is the
  start, not the finish
- changed anything that removes or replaces files? say how you tested the
  rollback, not just the happy path
- no personal data anywhere (MACs, names, IPs, home paths). the suite
  greps for it and CI fails on a hit

## know your patch

the updater runs as root on other people's machines. understand every line
you send, assistant-written ones included, and drop anything you can't
explain.

you need basic linux: the terminal, permissions, sudo, `~/.config`, and a
feel for what a package manager really does. guessing here has real
consequences, so it isn't contributing.

reviewers here are people, not bots: expect to answer questions about your
patch, and don't open one you can't back up. unattended drive-by or bot
PRs get closed.

## issues

use the bug report template and paste the diagnostics it asks for - distro,
package manager, the failing log line. trim anything personal. "it doesn't
work" on its own gets closed with a pointer back here.
