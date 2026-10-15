# review checklist

every change passes these five before it ships.

1. plain words. could a non-technical friend follow the README diff with
   no help? no jargon without an explanation next to it.
2. off by default. destructive or surprising actions stay opt-in
   (`UPDATE_AUR`, `UPDATE_CONTROLLERS`, passwordless sudo).
3. proven, not claimed. `bash tests/run.sh` green on the stub farm.
4. docs match code. README and CHANGELOG updated with the behavior. no
   personal data anywhere.
5. uninstall story intact. `--uninstall` asks about settings and logs,
   `--purge` removes everything. tested with a fake HOME, never live.
