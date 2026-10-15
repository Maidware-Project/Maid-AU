# contributing

small, reviewable changes only — one thing per pull request. read
AGENTS.md first (it applies to humans and AI assistants alike).

before opening anything:

- `bash tests/run.sh` green on your machine
- `bash install.sh --check` writes nothing
- no personal data anywhere (MACs, names, IPs, home paths) — the
  suite enforces this, CI fails it
- AI-assisted work: say so in the PR, keep it small enough to review
  without an assistant, never claim a test ran that didn't

issues: use the bug report template, paste the diagnostics it asks
for, trim personal data before posting publicly. "it doesn't work"
with nothing attached will be closed with a pointer back here.
