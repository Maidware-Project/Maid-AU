# Review checklist — pass all five before any change ships

1. **Plain words.** Could a non-technical friend follow the README
   diff with no help? No jargon without an explanation next to it.
2. **Off by default.** Destructive or surprising actions stay opt-in
   (`UPDATE_AUR`, `UPDATE_CONTROLLERS`, passwordless sudo).
3. **Proven, not claimed.** `bash tests/run.sh` green on stub farm.
4. **Docs match code.** README, CHANGELOG updated with the behavior.
   No personal data anywhere.
5. **Uninstall story intact.** `--uninstall` asks about settings/logs,
   `--purge` removes everything. Tested with a fake HOME, never live.
