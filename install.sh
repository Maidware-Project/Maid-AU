#!/usr/bin/env bash
# Universal installer: Arch (pacman), Debian/Ubuntu (apt), Fedora (dnf),
# openSUSE (zypper). Copies files (no symlinks - survives folder moves).
# Usage: ./install.sh [--check] [--no-packages] [--uninstall [--purge]]
#          [--prefix=DIR] [--no-config]
# --prefix installs program files elsewhere (packaging: DESTDIR supported);
# user setup is skipped for non-default prefixes and with --no-config.
set -u
PKGDIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
CHECK=0; NO_PKGS=0; UNINST=0; PURGE=0; NOCONFIG=0; PREFIX=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --no-packages) NO_PKGS=1 ;;
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

if [ "$UNINST" = "1" ]; then
  # program files come out of the same dirs the install used, so
  # --prefix/DESTDIR installs uninstall cleanly too.
  rm -f "$BINDIR"/update-all.sh "$BINDIR"/system-updater \
    "$BINDIR"/pm-zypper.sh "$BINDIR"/pm-dnf.sh \
    "$BINDIR"/pm-pacman.sh "$BINDIR"/pm-apt.sh \
    "$BINDIR"/setup-controllers.sh "$BINDIR"/check-controllers.sh
  rm -f "$SHAREDIR"/applications/system-updater.desktop
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

FAIL=0
for f in "$PKGDIR"/bin/*; do
  [ -f "$f" ] || continue
  copy_one "$f" "$BINDIR/$(basename "$f")" \
    || { warn "could not install $(basename "$f")"; FAIL=1; }
done
[ "$CHECK" = "0" ] && chmod +x "$BINDIR"/update-all.sh "$BINDIR"/system-updater 2>/dev/null || true

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
  copy_one "$f" "$SHAREDIR/applications/$(basename "$f")" "$REWRITE" \
    || { warn "could not install $(basename "$f")"; FAIL=1; }
done

# the kdeconnect early-login fix (kernel 7.2.11 / Plasma 6.8) travels
# with the suite: ~/.local/share/maid-au/patches/kdeconnect-26.08.2/
for f in "$PKGDIR"/patches/kdeconnect-26.08.2/*; do
  [ -f "$f" ] || continue
  copy_one "$f" \
    "$SHAREDIR/maid-au/patches/kdeconnect-26.08.2/$(basename "$f")" \
    || { warn "could not install $(basename "$f")"; FAIL=1; }
done

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
