# Maid AU — a auto updater for linux

flatpak + native packages + firmware, with notifications, logging,
tracking, and a --check mode that distinguishes app updates from
reboot-needed system updates. doesn't reboot for you.

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

## installation

```sh
bash install.sh            # deps (sudo) + copy + launcher
bash install.sh --check    # dry run
```

existing files are backed up to `*.bak-<timestamp>`. passwordless runs
are opt-in and risky: a NOPASSWD package manager rule is effectively
passwordless root for your user (it can install crafted local packages).
default is asking for sudo, which is fine. to opt in anyway the installer
prints a safe sequence (write temp file, `visudo -c -f` it first, install
with mode 0440). no network downloads anywhere in this package — every
dependency comes from your distro repos.

## usage

- launcher: **System Updater** (or `system-updater`, `update-all.sh`)
- `update-all.sh --check` — report only (app vs system/firmware)
- `update-all.sh --last` — when the last successful run happened
- AppImages in `~/AppImages` / `~/Applications` update via embedded
  info (`appimageupdatetool` when installed); extra direct links go in
  `~/.config/maidau-appimages.conf` as `Name|URL` lines (downloaded
  only when changed, old file backed up first)
- `update-all.sh --require-snapshot` — combine with a run: abort the
  system upgrade unless snapshots actually work (see safety)
- Log: `~/.local/share/update-all.log` (last 1000 lines kept)

## safety

never hold packages, always snapshot — that's the whole deal. every run
*attempts* a pre snapshot and a post snapshot (snapper on btrfs, timeshift
fallback) and tells you the numbers, so a bad update is a rollback away:
`sudo snapper -c root rollback <pre#>` (or boot one from GRUB).
honest version: snapshot failure does NOT stop the upgrade by default,
it gets logged loudly instead — pass `--require-snapshot` to make it
abort instead. on opensuse the zypper plugin already snapshots every dup,
we just report the pair + make sure `grub2-snapper-plugin` is there for
boot entries. `--check` shows your latest snapshot for reassurance.
holding kernels back is not offered on purpose — stale kernels break
out-of-tree modules worse than updates do.

## failure policy

- failed system upgrade, refresh, or firmware step → run marked FAILED,
  error notification, nothing hidden.
- failed controller update → also FAILED (reported distinctly). a merely
  unhealthy controller *check* never fails the run, just logs.
- failed AUR build (opt-in via `UPDATE_AUR=1`) → run marked PARTIAL,
  not failed: system packages are done, AUR needs a look.
- reboot hints are hints: name patterns everywhere, plus
  `/var/run/reboot-required` on apt, `needs-restarting -r` on dnf,
  staged-kernel-vs-boot comparison on pacman.

## controllers 

`controllers/` is the opensuse KMP stack (xone/xpadneo/joycond/
inputplumber/hid-tmff2) — kernel modules packaged per openSUSE kernel,
installed only on zypper systems, and only when you opt in:
`UPDATE_CONTROLLERS=1 update-all.sh`. without it the updater says so
up front and skips the whole thing. Elsewhere:
- **Arch**: community DKMS packages (`xone-dkms`, `xpadneo-dkms`) via
  your AUR helper; `joycond`/`inputplumber` from AUR/extra.
- **Fedora/Debian**: check community DKMS/COPR builds for your kernel;
  generic Xbox/PlayStation/Switch pads already work with in-kernel
  drivers (`xpad`, `hid-playstation`, `hid-nintendo`).
a failing health check never fails the run; a failed controller *update*
is reported as an error (see failure policy).

## repos

- zypper backend reports **packman** updates separately. dup runs with
  `--allow-vendor-change` because Tumbleweed stalls without it (Packman
  codec flips, repo moves) — scoped to this explicit manual run only.
- dnf backend counts **RPM Fusion** updates separately.
- pacman backend counts **AUR** updates when `yay`/`paru` exists; AUR
  *builds* only run with `UPDATE_AUR=1` (they execute PKGBUILD code).
- apt backend covers **every configured repo incl. PPAs** via apt.

## uninstall

```sh
rm ~/.local/bin/{update-all.sh,system-updater,pm-{zypper,dnf,pacman,apt}.sh,setup-controllers.sh,check-controllers.sh}
rm ~/.local/share/applications/system-updater.desktop
```

## License

MIT — see LICENSE.
