#!/usr/bin/env bash
# Universal installer: Arch (pacman), Debian/Ubuntu (apt), Fedora (dnf),
# openSUSE (zypper). Copies files (no symlinks — survives folder moves).
# Usage: ./install.sh [--check] [--no-packages]
set -u
PKGDIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
CHECK=0; NO_PKGS=0
[ "${1:-}" = "--check" ] && CHECK=1
[ "${1:-}" = "--no-packages" ] && NO_PKGS=1

say()  { echo "==> $*"; }
warn() { echo "!! $*" >&2; }

detect_pm() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
      *arch*) echo pacman; return ;;
      *debian*|*ubuntu*) echo apt; return ;;
      *fedora*|*rhel*|*centos*) echo dnf; return ;;
      *suse*|*opensuse*) echo zypper; return ;;
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
    *) warn "unsupported distro — install manually: flatpak fwupd libnotify-client"; REQ=() ;;
  esac
  if [ "${#REQ[@]}" -gt 0 ]; then
    say "installing: ${REQ[*]}"
    case "$PM" in
      pacman) sudo pacman -Sy --needed --noconfirm "${REQ[@]}" ;;
      apt) sudo apt-get update && sudo apt-get install -y "${REQ[@]}" ;;
      dnf) sudo dnf install -y "${REQ[@]}" ;;
      zypper) sudo zypper --non-interactive install "${REQ[@]}" ;;
    esac || warn "package install had errors — continuing (see README)"
  fi
else
  say "skipping packages (--no-packages)"
fi

copy_one() {
  local src="$1" dest="$2" rewrite="${3:-0}"
  if [ "$CHECK" = "1" ]; then echo "COPY $dest"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
    cp -a "$dest" "${dest}.bak-${BACKUP_TS}"
    say "backed up $dest"
  fi
  if [ "$rewrite" = "1" ]; then
    sed -e "s|/home/visa|$HOME|g" "$src" > "$dest"
  else
    cp -a "$src" "$dest"
  fi
  echo "installed $dest"
}

for f in "$PKGDIR"/bin/*; do
  [ -f "$f" ] || continue
  copy_one "$f" "$HOME/.local/bin/$(basename "$f")"
done
[ "$CHECK" = "0" ] && chmod +x "$HOME"/.local/bin/update-all.sh "$HOME"/.local/bin/system-updater 2>/dev/null || true

if [ "$PM" = "zypper" ]; then
  for f in "$PKGDIR"/controllers/*; do
    [ -f "$f" ] || continue
    copy_one "$f" "$HOME/.local/bin/$(basename "$f")"
  done
  [ "$CHECK" = "0" ] && chmod +x "$HOME"/.local/bin/setup-controllers.sh "$HOME"/.local/bin/check-controllers.sh 2>/dev/null || true
else
  say "controllers/ skipped (openSUSE-only KMP stack; see README for $PM)"
fi

for f in "$PKGDIR"/desktop/*.desktop; do
  [ -f "$f" ] || continue
  copy_one "$f" "$HOME/.local/share/applications/$(basename "$f")" 1
done

if [ "$CHECK" = "1" ]; then say "(check only, nothing changed)"; exit 0; fi
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

say "done. Backups (if any): *.bak-${BACKUP_TS}"
say "Optional passwordless updates (else you will be asked for sudo password):"
case "$PM" in
  pacman) say '  echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" | sudo tee /etc/sudoers.d/system-updater' ;;
  apt) say '  echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/apt-get" | sudo tee /etc/sudoers.d/system-updater' ;;
  dnf) say '  echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/dnf" | sudo tee /etc/sudoers.d/system-updater' ;;
  zypper) say '  echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/zypper" | sudo tee /etc/sudoers.d/system-updater' ;;
esac
say "Always validate sudoers edits with: sudo visudo -c"
