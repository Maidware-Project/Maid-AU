#!/usr/bin/env bash
# Universal installer: Arch (pacman), Debian/Ubuntu (apt), Fedora (dnf),
# openSUSE (zypper). Copies files (no symlinks - survives folder moves).
# Usage: ./install.sh [--check] [--no-packages] [--no-gui]
#          [--uninstall [--purge]] [--prefix=DIR] [--no-config]
# --prefix installs program files elsewhere (packaging: DESTDIR supported);
# user setup is skipped for non-default prefixes and with --no-config.
# The Qt6 GUI is built when cmake and Qt6 Widgets development files exist;
# --no-gui keeps the terminal-only install.
set -u
PKGDIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
CHECK=0; NO_PKGS=0; UNINST=0; PURGE=0; NOCONFIG=0; PREFIX=""; NO_GUI=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --no-packages) NO_PKGS=1 ;;
    --no-gui) NO_GUI=1 ;;
    --uninstall) UNINST=1 ;;
    --purge) PURGE=1 ;;
    --no-config) NOCONFIG=1 ;;
    --prefix=*) PREFIX="${a#--prefix=}" ;;
    *) echo "unknown option: $a (see header)" >&2; exit 2 ;;
  esac
done
if [ -z "$PREFIX" ]; then PREFIX="$HOME/.local"; fi
if [ "$PREFIX" = "$HOME/.local" ]; then
  BINDIR="$HOME/.local/bin"; SHAREDIR="$HOME/.local/share"; REWRITE=1
else
  BINDIR="${DESTDIR:-}$PREFIX/bin"; SHAREDIR="${DESTDIR:-}$PREFIX/share"; REWRITE=2
  NOCONFIG=1
fi

say()  { echo "==> $*"; }
warn() { echo "!! $*" >&2; }

# Report the KDE stack so install logs show what this machine runs.
kde_env() {
  local plasma fw qt kc
  plasma=$(plasmashell --version 2>/dev/null | awk 'NR==1{print $2}')
  [ -n "$plasma" ] || plasma=$(kwin_wayland --version 2>/dev/null | awk 'NR==1{print $2}')
  fw=$(kf6-config --version 2>/dev/null)
  [ -n "$fw" ] || fw=$(pkg-config --modversion KF6CoreAddons 2>/dev/null)
  [ -n "$fw" ] || fw=$(rpm -q --qf '%{VERSION}' kf6-kcoreaddons 2>/dev/null)
  [ -n "$fw" ] || fw=$(dpkg-query -W -f='${Version}' libkf6coreaddons6 2>/dev/null)
  [ -n "$fw" ] || fw=$(pacman -Q kf6-kcoreaddons 2>/dev/null | awk '{print $2}')
  qt=$(qmake6 -query QT_VERSION 2>/dev/null)
  [ -n "$qt" ] || qt=$(qtpaths6 --qt-version 2>/dev/null)
  [ -n "$qt" ] || qt=$(pkg-config --modversion Qt6Core 2>/dev/null)
  kc=$(kdeconnectd --version 2>/dev/null | awk 'NR==1{print $NF}')
  [ -n "$kc" ] || kc=$(kdeconnect-cli --version 2>/dev/null | awk 'NR==1{print $NF}')
  KDE_PLASMA="$plasma"
  KDE_FRAMEWORKS="$fw"
  KDE_QT="$qt"
  KDE_CONNECT="$kc"
}
kde_env_line() {
  if [ -z "${KDE_PLASMA:-}${KDE_FRAMEWORKS:-}${KDE_QT:-}${KDE_CONNECT:-}" ]; then
    echo "KDE: not detected (non-KDE session or tools missing)"
  else
    echo "KDE: Plasma ${KDE_PLASMA:-?} | Frameworks ${KDE_FRAMEWORKS:-?} | Qt ${KDE_QT:-?} | KDE Connect ${KDE_CONNECT:-not installed}"
  fi
}
kde_env
say "$(kde_env_line)"

if [ "$UNINST" = "1" ]; then
  # program files come out of the same dirs the install used, so
  # --prefix/DESTDIR installs uninstall cleanly too.
  rm -f "$BINDIR"/update-all.sh "$BINDIR"/system-updater "$BINDIR"/maid-au-gui \
    "$BINDIR"/pm-zypper.sh "$BINDIR"/pm-dnf.sh \
    "$BINDIR"/pm-pacman.sh "$BINDIR"/pm-apt.sh \
    "$BINDIR"/setup-controllers.sh "$BINDIR"/check-controllers.sh
  rm -f "$SHAREDIR"/applications/system-updater.desktop \
    "$SHAREDIR"/applications/maid-au.desktop
  rm -rf "$SHAREDIR"/maid-au/patches
  if [ "$PURGE" = "1" ]; then
    rm -f "$HOME"/.config/maidau-appimages.conf "$HOME"/.local/share/update-all.log \
      "$HOME"/.local/share/update-all.last "$HOME"/.local/share/maidau-appimages.state
    say "uninstalled, settings, logs and state removed (--purge)"
  elif [ -t 0 ]; then
    printf 'Remove settings, logs and state too (~/.config/maidau-appimages.conf,
update log/last, appimage state)? [y/N]: '
    read -r _ans
    case "$_ans" in [Yy]*)
      rm -f "$HOME"/.config/maidau-appimages.conf "$HOME"/.local/share/update-all.log \
        "$HOME"/.local/share/update-all.last "$HOME"/.local/share/maidau-appimages.state
      say "uninstalled, settings, logs and state removed" ;;
    *) say "uninstalled, settings, logs and state kept" ;;
    esac
  else
    say "uninstalled (kept: settings, logs and state; rerun with --purge to remove)"
  fi
  exit 0
fi

detect_pm() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
      *arch*) echo pacman; return ;;
      *debian*|*ubuntu*) echo apt; return ;;
      *fedora*|*rhel*|*centos*) echo dnf; return ;;
      *suse*) echo zypper; return ;;
    esac
  fi
  for c in pacman apt-get dnf zypper; do
    if command -v "$c" >/dev/null 2>&1; then
      case "$c" in
        pacman) echo pacman; return ;;
        apt-get) echo apt; return ;;
        dnf) echo dnf; return ;;
        zypper) echo zypper; return ;;
      esac
    fi
  done
  echo none
}

PM=$(detect_pm)
if [ "$CHECK" = "1" ]; then
  say "package manager: $PM (check only, nothing installed)"
elif [ "$NO_PKGS" = "0" ]; then
  case "$PM" in
    pacman) REQ=(flatpak fwupd libnotify pacman-contrib) ;;
    apt) REQ=(flatpak fwupd libnotify-bin) ;;
    dnf) REQ=(flatpak fwupd libnotify) ;;
    zypper) REQ=(flatpak fwupd libnotify-tools) ;;
    *) warn "unsupported distro - install manually: flatpak fwupd libnotify-client"; REQ=() ;;
  esac
  if [ "${#REQ[@]}" -gt 0 ]; then
    say "installing: ${REQ[*]}"
    case "$PM" in
      # NOTE: full -Syu, never -Sy alone - Arch does not support partial
      # upgrades (refreshed db + old packages breaks).
      pacman) sudo pacman -Syu --needed --noconfirm "${REQ[@]}" ;;
      apt) sudo apt-get update && sudo apt-get install -y "${REQ[@]}" ;;
      dnf) sudo dnf install -y "${REQ[@]}" ;;
      zypper) sudo zypper --non-interactive install "${REQ[@]}" ;;
    esac || warn "package install had errors - continuing (see README)"
  fi
else
  say "skipping packages (--no-packages)"
fi

copy_one() {
  local src="$1" dest="$2" rewrite="${3:-0}" tmp=""
  if [ "$CHECK" = "1" ]; then echo "COPY $dest"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  # render first, compare second: $src still holds the Exec-path
  # placeholder, which never equals an installed file - comparing raw
  # would back up on every run. compare what we would write instead.
  tmp="$(mktemp)" || return 1
  if [ "$rewrite" = "1" ]; then
    # escape & (sed replacement metachar) in $HOME
    sed -e "s|@HOME@|${HOME//&/\\&}|g" "$src" > "$tmp"
  elif [ "$rewrite" = "2" ]; then
    # system package: bare command names, resolved via PATH
    sed -e "s|@HOME@||g" -e "s|/.local/bin/||g" "$src" > "$tmp"
  else
    cp -a "$src" "$tmp"
  fi
  if [ -e "$dest" ] && ! cmp -s "$tmp" "$dest"; then
    if ! cp -a "$dest" "${dest}.bak-${BACKUP_TS}"; then
      warn "backup failed, not replacing $dest"
      rm -f "$tmp"
      return 1
    fi
    say "backed up $dest"
  fi
  cat "$tmp" > "$dest"
  rm -f "$tmp"
  echo "installed $dest"
}

# The GUI is optional at build time: a terminal-only install still works
# on machines without cmake or Qt6 development packages.
GUI_INSTALLED=0
build_gui() {
  local src="$PKGDIR/gui" builddir jobs
  [ -d "$src" ] || { warn "gui/ missing - GUI skipped"; return 0; }
  if [ "$NO_GUI" = "1" ]; then
    say "GUI skipped (--no-gui)"
    return 0
  fi
  if [ "$CHECK" = "1" ]; then
    GUI_INSTALLED=1
    echo "BUILD $BINDIR/maid-au-gui (if cmake + Qt6 Widgets dev files are present)"
    return 0
  fi
  if ! command -v cmake >/dev/null 2>&1; then
    warn "GUI not built: cmake not found (terminal updater still installed)"
    return 0
  fi
  builddir=$(mktemp -d) || return 0
  jobs=$(nproc 2>/dev/null || echo 2)
  say "building the Qt6 GUI..."
  if cmake -S "$src" -B "$builddir" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 \
     && cmake --build "$builddir" -j"$jobs" >/dev/null 2>&1 \
     && [ -x "$builddir/maid-au-gui" ]; then
    if install -m 0755 "$builddir/maid-au-gui" "$BINDIR/maid-au-gui"; then
      say "installed $BINDIR/maid-au-gui"
      GUI_INSTALLED=1
    else
      warn "could not install maid-au-gui"
    fi
  else
    warn "GUI not built: install cmake and Qt6 Widgets development files"
    warn "  openSUSE: qt6-base-devel | Arch: qt6-base | Fedora: qt6-qtbase-devel | Debian: qt6-base-dev"
  fi
  rm -rf "$builddir"
}

FAIL=0
for f in "$PKGDIR"/bin/*; do
  [ -f "$f" ] || continue
  copy_one "$f" "$BINDIR/$(basename "$f")" \
    || { warn "could not install $(basename "$f")"; FAIL=1; }
done
[ "$CHECK" = "0" ] && chmod +x "$BINDIR"/update-all.sh "$BINDIR"/system-updater 2>/dev/null || true

build_gui

if [ "$PM" = "zypper" ]; then
  for f in "$PKGDIR"/controllers/*; do
    [ -f "$f" ] || continue
    copy_one "$f" "$BINDIR/$(basename "$f")" \
      || { warn "could not install $(basename "$f")"; FAIL=1; }
  done
  [ "$CHECK" = "0" ] && chmod +x "$BINDIR"/setup-controllers.sh "$BINDIR"/check-controllers.sh 2>/dev/null || true
else
  say "controllers/ skipped (openSUSE-only KMP stack; see README for $PM)"
fi

for f in "$PKGDIR"/desktop/*.desktop; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  # the GUI launcher only makes sense when the GUI binary is present
  if [ "$base" = "maid-au.desktop" ] \
     && [ "$GUI_INSTALLED" != "1" ] && [ ! -x "$BINDIR/maid-au-gui" ]; then
    [ "$CHECK" = "1" ] && echo "SKIP $SHAREDIR/applications/$base (GUI not built)"
    continue
  fi
  copy_one "$f" "$SHAREDIR/applications/$base" "$REWRITE" \
    || { warn "could not install $base"; FAIL=1; }
done

# the kdeconnect early-login fix lives in Maid Helper's `kdeconnect`
# doctor (maid-helper --only kdeconnect --fix); it is not shipped here.
# clean a stale patch copy left by older installs
if [ "$CHECK" = "0" ]; then rm -rf "$SHAREDIR/maid-au/patches"; fi

if [ "$CHECK" = "1" ]; then say "(check only, nothing changed)"; exit 0; fi
if [ "$FAIL" = "1" ]; then
  warn "install incomplete: some files failed to install"
  exit 1
fi
# user setup: menu cache refresh, skipped with --no-config / packaging
if [ "$NOCONFIG" = "0" ]; then
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
fi

say "done. Backups (if any): *.bak-${BACKUP_TS}"
say "passwordless updates are OPTIONAL and risky: a NOPASSWD package"
say "manager rule is effectively passwordless root for your user."
say "default is asking for your sudo password each run. to opt in:"
case "$PM" in
  pacman) BIN=/usr/bin/pacman ;;
  apt) BIN=/usr/bin/apt-get ;;
  dnf) BIN=/usr/bin/dnf ;;
  zypper) BIN=/usr/bin/zypper ;;
  *) BIN="" ;;
esac
if [ -n "$BIN" ]; then
  say "  T=\$(mktemp) && echo \"\$USER ALL=(ALL) NOPASSWD: $BIN\" > \$T"
  say "  sudo visudo -c -q -f \$T && sudo install -m 0440 \$T /etc/sudoers.d/system-updater && rm -f \$T"
fi
