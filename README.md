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

existing files are backed up to `*.bak-<timestamp>`. For passwordless
one-button runs, add a sudoers drop-in (installer prints the exact line
for your package manager) and validate with `sudo visudo -c`.
Without it, the updater asks for your sudo password in the terminal.

## usage

- launcher: **System Updater** (or `system-updater`, `update-all.sh`)
- `update-all.sh --check` — report only (app vs system/firmware)
- `update-all.sh --last` — when the last successful run happened
- Log: `~/.local/share/update-all.log` (last 300 lines kept)

## safety

never hold packages, always snapshot — that's the whole deal. every run
takes a pre snapshot and a post snapshot (snapper on btrfs, timeshift
fallback) and tells you the numbers, so a bad update is a rollback away:
`sudo snapper -c root rollback <pre#>` (or boot one from GRUB).
on opensuse the zypper plugin already snapshots every dup, we just report
the pair + make sure `grub2-snapper-plugin` is there for boot entries.
`--check` shows your latest snapshot for reassurance. holding kernels
back is not offered on purpose — stale kernels break out-of-tree modules
worse than updates do.

## controllers 

`controllers/` is the opensuse KMP stack (xone/xpadneo/joycond/
inputplumber/hid-tmff2) — kernel modules packaged per openSUSE kernel,
installed only on zypper systems. Elsewhere:
- **Arch**: community DKMS packages (`xone-dkms`, `xpadneo-dkms`) via
  your AUR helper; `joycond`/`inputplumber` from AUR/extra.
- **Fedora/Debian**: check community DKMS/COPR builds for your kernel;
  generic Xbox/PlayStation/Switch pads already work with in-kernel
  drivers (`xpad`, `hid-playstation`, `hid-nintendo`).
the updater logs a pointer and moves on — it never fails the run over this. (usually)

## repos

- zypper backend reports **packman** updates separately.
- dnf backend counts **RPM Fusion** updates separately.
- pacman backend counts **AUR** updates when `yay`/`paru` exists.
- apt backend covers **every configured repo incl. PPAs** via apt.

## uninstall

```sh
rm ~/.local/bin/{update-all.sh,system-updater,pm-{zypper,dnf,pacman,apt}.sh,setup-controllers.sh,check-controllers.sh}
rm ~/.local/share/applications/system-updater.desktop
```

## License

MIT — see LICENSE.
