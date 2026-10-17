#!/usr/bin/env bash
# Build .deb, .rpm and Arch packages from the staged install.
#
# One place owns the file list: the contents are taken from what
# install.sh actually stages, so the packages cannot drift from the
# installer. All three formats are architecture-independent (the tool
# is bash), so a single package fits every machine.
#
# Distro package names differ, so anything that is not the same
# everywhere goes in the per-format *_recommends lists below (the names
# mirror the installer's own per-distro lists).
#
# Usage: VERSION=0.1.0 packaging/packages.sh [OUTDIR]
#   needs nfpm on PATH (https://nfpm.goreleaser.com). OUTDIR default: ./dist
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${1:-$root/dist}"
version="${VERSION:-0.0.0}"

# metadata that does not change between builds
name="maid-au"
desc="One updater for everything on Linux (native, flatpak, firmware, snapshots first)"
homepage="https://github.com/Maidware-Project/Maid-AU"
depends=""                        # the updater adapts to whatever is present
recommends=""                     # named differently per distro
suggests=""
deb_recommends="flatpak fwupd libnotify-bin"
rpm_recommends="flatpak fwupd libnotify"
arch_recommends="flatpak fwupd libnotify pacman-contrib"

stage="$(mktemp -d)"
cfg="$(mktemp)"
trap 'rm -rf "$stage" "$cfg"' EXIT

# one install into a staging dir - the same files the installer would place
DESTDIR="$stage" bash "$root/install.sh" --prefix=/usr --no-packages --no-config >/dev/null

emit() { # emit <indent> <key> <space-separated values>
  local indent="$1" key="$2" values="${3:-}"
  [ -n "$values" ] || return 0
  printf '%s%s:\n' "$indent" "$key"
  local v
  for v in $values; do printf '%s  - "%s"\n' "$indent" "$v"; done
}

{
  printf 'name: "%s"\n' "$name"
  printf 'arch: all\n'
  printf 'platform: linux\n'
  printf 'version: "%s"\n' "$version"
  printf 'section: utils\n'
  printf 'priority: optional\n'
  printf 'maintainer: "visa <maidwareproject@proton.me>"\n'
  printf 'description: "%s"\n' "$desc"
  printf 'vendor: "Maidware Project"\n'
  printf 'homepage: "%s"\n' "$homepage"
  printf 'license: "MIT"\n'
  emit "" depends "$depends"
  emit "" recommends "$recommends"
  emit "" suggests "$suggests"
  if [ -n "$deb_recommends$rpm_recommends$arch_recommends" ]; then
    printf 'overrides:\n'
    [ -n "$deb_recommends" ] && { printf '  deb:\n'; emit "    " recommends "$deb_recommends"; }
    [ -n "$rpm_recommends" ] && { printf '  rpm:\n'; emit "    " recommends "$rpm_recommends"; }
    [ -n "$arch_recommends" ] && { printf '  archlinux:\n'; emit "    " recommends "$arch_recommends"; }
  fi
  printf 'contents:\n'
  find "$stage" -mindepth 1 \( -type f -o -type l \) | sort | while read -r p; do
    printf '  - src: "%s"\n    dst: "%s"\n' "$p" "${p#"$stage"}"
  done
} > "$cfg"

mkdir -p "$out"
rm -f "$out"/"$name"*.deb "$out"/"$name"*.rpm "$out"/"$name"*.pkg.tar.zst "$out"/SHA256SUMS
nfpm package -f "$cfg" -p deb -t "$out/${name}_all.deb"
nfpm package -f "$cfg" -p rpm -t "$out/${name}.noarch.rpm"
nfpm package -f "$cfg" -p archlinux -t "$out/${name}-any.pkg.tar.zst"

# checksums, so a download can be checked before it is installed
( cd "$out" && sha256sum "${name}_all.deb" "${name}.noarch.rpm" "${name}-any.pkg.tar.zst" > SHA256SUMS )

ls -l "$out"
