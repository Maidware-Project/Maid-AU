# contributing

small, reviewable changes only - one logical change per pull request
(the kernel puts it well: one patch, one problem; if your description
gets long, split it). read AGENTS.md first (it applies to humans and
AI assistants alike). maintained by Maidware Project.

## commits

- short lowercase summaries with a prefix: `fix:`, `feat:`, `docs:`,
  `tests:`, `chore:` - e.g. `fix: print PARTIAL when only the flatpak
  layer fails`
- sign off every commit (`git commit -s` appends it):
  `Signed-off-by: Your Name <you@example.com>`
  (developer's certificate of origin - proves you may contribute it)
- AI-assisted work gets an `Assisted-by:` trailer naming the tool,
  e.g. `Assisted-by: opencode (muse-spark)`. the kernel requires this;
  so do we. never claim a test ran that didn't.
- bug fixes reference what they fix: `Fixes: #123` or
  `Closes: #123` (issue number, or the symptom if no issue exists).

## before opening anything

- `bash tests/run.sh` green on your machine - paste the results
  in the PR (the template asks for them). tested on openSUSE; Arch
  and Fedora too if you can (VM or live USB counts - say which).
- `bash install.sh --check` writes nothing
- hardware touched? say what device/distro you verified live
- no personal data anywhere (MACs, names, IPs, home paths) - the
  suite enforces this, CI fails it
- lay out the fix: what broke, what you changed, why that way


## know your patch

understand every line you send, assistant-written parts included. if you
can't say what a line does, drop it. "the assistant wrote it" doesn't
answer the question.

you need basic linux: the terminal, file permissions, what sudo does,
where configs live (~/.config). not an expert, but this project ships
scripts that run on other people's machines, so guessing isn't
contributing.

## issues

use the bug report template, paste the diagnostics it asks for, trim
personal data before posting publicly. "it doesn't work" with nothing
attached will be closed with a pointer back here.
