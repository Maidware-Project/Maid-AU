# Maid AU — one updater for everything on linux

one click updates it all: system packages, flatpak apps, firmware.
it tells you what changed, warns when a reboot is needed, and never
reboots for you.
## layout

```
bin/update-all.sh     core: lock, log, notify, flatpak, fwupd, summary
bin/pm-zypper.sh      backend: openSUSE (dist-upgrade + packman repo)
bin/pm-dnf.sh         backend: Fedora/RHEL (upgrade + RPM Fusion count)
bin/pm-pacman.sh      backend: Arch (Syu + optional AUR via yay/paru)
bin/pm-apt.sh         backend: Debian/Ubuntu (all repos incl. PPAs)
bin/system-updater    GUI entry: sleep-inhibited terminal picker
controllers/          openSUSE-only controller stack (KMPs — see below)
desktop/              launcher icon
install.sh            multi-distro installer
```

backend auto-detected from `/etc/os-release`, override with
`UPDATE_PM=zypper ./bin/update-all.sh --check`.

## requirements per distro

| Need | Arch | Debian/Ubuntu | Fedora | openSUSE |
|---|---|---|---|---|
| flatpak/fwupd/notify | flatpak fwupd libnotify (+pacman-contrib for `checkupdates`) | flatpak fwupd libnotify-bin | flatpak fwupd libnotify | flatpak fwupd libnotify-tools |

no services here — everything runs on demand when you click it, so init
doesn't matter. fork it for whatever setup you run.

## installation

```sh
bash install.sh            # deps (sudo) + copy + launcher
bash install.sh --check    # dry run
```

existing files are backed up to `*.bak-<timestamp>` (only when content
actually changed — reinstalls don't pile up copies). passwordless runs
are opt-in and risky: a NOPASSWD package manager rule is effectively
passwordless root for your user (it can install crafted local packages).
default is asking for sudo, which is fine. to opt in anyway the installer
prints a safe sequence (write temp file, `visudo -c -f` it first, install
with mode 0440). no network downloads anywhere in this package — every
dependency comes from your distro repos.

## usage

- launcher: **System Updater** (or run `system-updater` /
  `update-all.sh` in a terminal)
- `update-all.sh --check` — dry run: shows what *would* update,
  split into apps vs system/firmware, changes nothing
- `update-all.sh --last` — when the last successful run happened
- AppImages in `~/AppImages` / `~/Applications` update via embedded
  info (`appimageupdatetool` when installed); extra direct links go in
  `~/.config/maidau-appimages.conf` as `Name|URL` lines (downloaded
  only when changed, old file backed up first)
- `update-all.sh --require-snapshot` — combine with a run: abort the
  system upgrade unless snapshots actually work (see safety)
- Log: `~/.local/share/update-all.log` (last 1000 lines kept)

## safety (snapshots before everything)

every run takes a snapshot before *and* after updating (snapper on
btrfs, timeshift otherwise) and tells you their numbers. bad update?
roll back: `sudo snapper -c root rollback <pre#>` (or pick one in GRUB).

two honest caveats: if snapshotting itself fails, the upgrade still
goes ahead by default (it gets logged loudly) — pass
`--require-snapshot` to make it abort instead. and kernels are never
held back on purpose: an old kernel breaks drivers worse than any
update does.

## if something fails

- a failed system, refresh, or firmware step marks the whole run
  FAILED and pops an error notification. nothing is hidden.
- a failed controller *update* also fails the run (said plainly which
  one). a merely unhealthy controller *check* just gets logged.
- a failed AUR build (only if you opted in with `UPDATE_AUR=1`) marks
  the run PARTIAL: system packages are done, one AUR package needs a
  look — not a failure.
- "reboot needed" is always just a hint, detected per-distro.

## game controllers

`controllers/` handles gamepad drivers (xbox/playstation/switch pads).
on openSUSE it installs matching kernel modules, but only if you opt
in: `UPDATE_CONTROLLERS=1 update-all.sh`. without it the updater says
so up front and skips the whole thing. elsewhere:
- **Arch**: community DKMS packages (`xone-dkms`, `xpadneo-dkms`) via
  your AUR helper; `joycond`/`inputplumber` from AUR/extra.
- **Fedora/Debian**: check community DKMS/COPR builds for your kernel;
  generic Xbox/PlayStation/Switch pads already work with in-kernel
  drivers (`xpad`, `hid-playstation`, `hid-nintendo`).
a failing health check never fails the run; a failed controller *update*
is reported as an error (see failure policy).

## distro extras

- openSUSE: packman updates are reported separately; upgrades allow
  vendor change (Tumbleweed stalls without it).
- Fedora: RPM Fusion updates counted separately.
- Arch: AUR updates counted when `yay`/`paru` exists; AUR *builds*
  only run with `UPDATE_AUR=1` (they run other people's build code).
- Debian/Ubuntu: every configured repo including PPAs is covered.

## uninstall

```sh
bash install.sh --uninstall            # everything out, asks about settings + logs
bash install.sh --uninstall --purge    # everything out including those, no questions
```

packaged installs (`--prefix=/usr`, e.g. the AUR package) uninstall
from the same prefix — `pacman -R` also works there as usual.

## License

MIT — see LICENSE.

## the Maid suite (BT, Maidshare, watcher, Helper)

Maid AU knows its own family: `--check` reports when your Maid checkouts
are behind upstream, a full run pulls them `--ff-only`, and
`UPDATE_MAID_DEPLOY=1` also reruns each project's installer.
Opt out anytime with `MAID_SUITE=0`.

## Linux Mint

Works like Ubuntu (same `apt` path, including LMDE via Debian). No extra steps.
