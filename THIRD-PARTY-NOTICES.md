# third-party and credits

Maid AU is Maidware work under the **GPL-3.0-or-later** license in `LICENSE`. It does not bundle third-party software; it orchestrates system updaters and snapshot tools provided by your distribution.

## Called at runtime, not bundled
Provided by your system/distribution (backend depends on distro):
- **bash** and core userland.
- **Package managers:** `pacman` (Arch), `apt-get`/`apt` (Debian/Ubuntu), `dnf` (Fedora/RHEL family), `zypper` (openSUSE/SUSE) — each under its own license.
- **flatpak** (LGPL-2.1+): application updates.
- **fwupd / fwupdmgr** (LGPL-2.1+): firmware updates (where available).
- **snapper** (GPL-2.0, common on Btrfs/SUSE) and/or **timeshift** (GPL): filesystem snapshots before/after upgrade runs when configured/available.
- **systemd-inhibit** / login/session tooling (where used) to avoid interruptions during runs.
- **notify-send** / desktop notification tools (optional): user notifications.
- **curl/wget** may be used by underlying system tooling; Maid AU’s core scripts invoke the above system tools.

Everything else in this repository is original Maidware work. Corrections welcome.
