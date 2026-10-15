# security

Maid AU updates the machine: distro packages, flatpak, AUR and appimages.
the supply chain it touches, and how it is handled:

- appimage downloads are https-only (`curl --proto '=https'`) and checked
  against a pinned sha256 you set. a mismatch is logged and the file is
  never installed; a malformed pin is refused outright. covered by
  `tests/run.sh`.
- package updates go through your own package manager, over its own
  signatures. the installer fetches nothing itself.
- a snapshot is taken before a real run, so a bad update can be rolled back.
- no `eval`, no shell strings; argv lists throughout.

one thing to know: with `XONEDO=1` (off by default) the controller step
clones a third-party driver (`OpenGamingCollective/xonedo`) and builds it
as root. that is not maidware code and it moves under you; the script
prints a warning and accepts `XONEDO_REF=<commit>` to pin it. see
`controllers/setup-controllers.sh`.

to report a problem, open an issue on the repository.
