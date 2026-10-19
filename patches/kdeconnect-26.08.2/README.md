# kdeconnectd early-login crash — kernel 7.2.11 / Plasma 6.8 fix

After the upgrade to kernel 7.2.11 and KDE Plasma 6.8.0 (Qt 6.11.2),
`kdeconnectd` dumped core on login:

```
kdeconnectd[15193]: could not connect to display
Could not load the Qt platform plugin "xcb" in "" even though it was found.
This application failed to start because no Qt platform plugin could be initialized.
```

## cause

`kdeconnectd` is D-Bus activated, and at login it can start before the
session environment (`XDG_SESSION_TYPE`, `WAYLAND_DISPLAY`) has been
propagated to the systemd user instance. `DISPLAY` is already set at that
point, so Qt's automatic platform detection picks `xcb` — but Xwayland is
not accepting connections yet. Qt treats a failed platform plugin as fatal
(`qFatal`), so the daemon aborts and leaves a core dump.

## fix

`daemon/kdeconnectd.cpp` (`detectPlatform()`):

- probe `XDG_RUNTIME_DIR` for a `wayland-*` socket when `WAYLAND_DISPLAY`
  is missing, so the compositor is found even before the variable is
  exported;
- always set `QT_QPA_PLATFORM` to an ordered fallback list
  (`wayland;xcb;offscreen` or `xcb;wayland;offscreen`) instead of letting
  Qt pick one fatal platform. Worst case the daemon runs with the
  `offscreen` platform (logged with a warning) instead of aborting.

## patches

- `0001-daemon-platform-fallback.patch` — upstream-style git patch,
  applies with `git am` or `patch -p1` to kdeconnect-kde 26.08.2.
- `kdeconnectd-platform-fallback.patch` — the same change as used by the
  local RPM build (`Patch1` in `kdeconnect-kde.spec`).

```
cd kdeconnect-kde-26.08.2
patch -p1 < kdeconnectd-platform-fallback.patch
cmake -B build -DBUILD_TESTING=OFF && cmake --build build
```
