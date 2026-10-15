# contributing

small, reviewable changes only — one thing per pull request. read
AGENTS.md first (it applies to humans and AI assistants alike).

before opening anything:

- `bash tests/run.sh` green on your machine — paste the results
  in the PR (the template asks for them)
- `bash install.sh --check` writes nothing
- hardware touched? say what device/distro you verified live
- no personal data anywhere (MACs, names, IPs, home paths) — the
  suite enforces this, CI fails it
- AI-assisted work: say so in the PR, keep it small enough to review
  without an assistant, never claim a test ran that didn't
- lay out the fix: what broke, what you changed, why that way

issues: use the bug report template, paste the diagnostics it asks
for, trim personal data before posting publicly. "it doesn't work"
with nothing attached will be closed with a pointer back here.
