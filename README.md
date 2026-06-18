# spot - Pure Assembly Presenter Spotlight

<img src="img/spot.svg" align="left" width="150" height="150">

![Version](https://img.shields.io/badge/version-0.1.3-blue)
![Assembly](https://img.shields.io/badge/language-x86__64%20Assembly-purple)
![License](https://img.shields.io/badge/license-Unlicense-green)
![Platform](https://img.shields.io/badge/platform-Linux%20x86__64-blue)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![Binary](https://img.shields.io/badge/binary-~14KB-orange)
![Startup](https://img.shields.io/badge/startup-~1ms-ff6600)
![Idle](https://img.shields.io/badge/idle%20cost-0%20W-brightgreen)
![Suite](https://img.shields.io/badge/suite-CHasm-9333ea)

Presenter spotlight overlay for the [CHasm](https://github.com/isene/chasm)
desktop suite. Darkens the whole screen, cuts a clean window around the
mouse pointer. Works on every workspace and over screen-share (Teams,
Discord, Meet capture the composited framebuffer, which includes us).

Single static 14 KB ELF, no libc, pure x86_64 NASM. X11 wire protocol +
SHAPE extension over a Unix socket. Zero idle cost: only runs when
launched, exits cleanly on Esc.

<br clear="left"/>

## Modes

| Mode | Status | Bound to |
|------|--------|----------|
| **spotlight** | ✓ shipped | `Mod4+Shift+s` (tile) |
| **highlight** (drag-rect) | planned | `Mod4+Shift+h` |
| **draw** (annotate) | planned | `Mod4+Shift+d` |

## Install

```bash
git clone https://github.com/isene/spot.git
cd spot
make
sudo make install
```

Add to `~/.tilerc`:

```
bind Mod4+Shift+s   exec spot
```

## Configuration

`SPOT_DIM=<0..100>` env var controls the surround brightness:

| Value | Effect |
|-------|--------|
| `100` | pure black surround |
| `80`  | default — `#333333` |
| `50`  | medium gray `#808080` |
| `0`   | white surround |

```
bind Mod4+Shift+s   exec env SPOT_DIM=70 spot
```

v0.1.3+ shows the **actual screen content darkened** (not a solid colour).
At startup, spot does `XGetImage` on root, multiplies every R/G/B channel
by `(100 - SPOT_DIM) / 100`, and uploads the result as the overlay's
back pixmap. No compositor needed — the snapshot is just bytes on the
server side, painted as the window background.

Caveat: it's a **snapshot**. If something behind spot animates / scrolls
/ repaints while spot is running, the dimmed surround stays as it was at
startup. Fine for presenting static slides. Less great for live demos
where windows below are updating; in that case, exit spot and re-launch.

## How it works

- Override-redirect InputOutput window covers the root with a fill
  computed from `SPOT_DIM`. The X server's free background fill does
  the painting; no per-frame draw calls.
- `SHAPE` extension, kind `Input`, rectangles `{}` → window has no input
  region. All pointer events pass straight through. You can keep
  interacting with the application underneath while the spotlight is up.
- `SHAPE` extension, kind `Bounding`, ~564 per-row rectangles
  approximating a circle of radius 140 px. The disk at the pointer is
  excluded → underlying screen shows through.
- A precomputed `circle_hw[]` table holds the circle's horizontal
  half-width at every row (built in ~140 iterations at startup, then
  static).
- Cursor tracking polls `XQueryPointer` at 30 Hz. On actual motion
  (delta ≥ 1 px), one `SHAPE Rectangles` request rewrites the bound.
  Still cursor = zero requests, zero CPU.
- Passive `GrabKey` on root for **Esc** and **q** (AnyModifier) so the
  keys reach us regardless of input focus. Avoids the v0.1.0 issue where
  `GrabKeyboard` on the freshly-mapped overlay window could race with
  the X server's `MapNotify` and silently fail (`NotViewable`), leaving
  Esc unbound.

## Goals (CHasm rules in priority order)

1. **No wasted CPU.** Single SHAPE-rect request per cursor motion event.
   No animation loops, no compositor wakeups.
2. **Lightning fast.** ~1 ms cold start (one syscall to connect, four to
   create + map + grab + flush). Instantaneous show / hide.
3. **More battery.** Idle: not running. Active + still cursor: not
   redrawing. Active + moving: one X request per ≥1 px delta.

## License

[Unlicense](https://unlicense.org/) - public domain.

## Credits

Created by Geir Isene (https://isene.org) with pair-programming via Claude Code.
