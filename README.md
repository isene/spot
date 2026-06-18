# spot - Pure Assembly Presenter Spotlight

<img src="img/spot.svg" align="left" width="150" height="150">

![Version](https://img.shields.io/badge/version-0.3.0-blue)
![Assembly](https://img.shields.io/badge/language-x86__64%20Assembly-purple)
![License](https://img.shields.io/badge/license-Unlicense-green)
![Platform](https://img.shields.io/badge/platform-Linux%20x86__64-blue)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![Binary](https://img.shields.io/badge/binary-~22KB-orange)
![Startup](https://img.shields.io/badge/startup-~1ms-ff6600)
![Idle](https://img.shields.io/badge/idle%20cost-0%20W-brightgreen)
![Suite](https://img.shields.io/badge/suite-CHasm-9333ea)

Presenter overlays for the [CHasm](https://github.com/isene/chasm)
desktop suite. Three modes from one binary: **spotlight** (dimmed
screen, circular hole follows the cursor), **draw** (click-drag to
annotate), **highlight** (click-drag a rectangle that stays bright
while the surround stays dim). Works on every workspace and over
screen-share (Teams, Discord, Meet capture the composited framebuffer,
which includes us).

Single static ~21 KB ELF, no libc, pure x86_64 NASM. X11 wire protocol
+ SHAPE extension over a Unix socket. Every key passes through to the
focused application — type, click, navigate slides while the overlay
is up. Toggle via the launch key (a second press kills it).

<br clear="left"/>

## Modes

| Mode | Status | Bound to |
|------|--------|----------|
| **spotlight** | ✓ shipped (v0.1.0) | `Mod4+Shift+s` (tile) |
| **draw** (annotate) | ✓ shipped (v0.2.0) | `Mod4+Shift+d` (tile) |
| **highlight** (drag-rect) | ✓ shipped (v0.3.0) | `Mod4+Shift+h` (tile) |

## Install

```bash
git clone https://github.com/isene/spot.git
cd spot
make
sudo make install
```

Add toggle bindings to `~/.tilerc` (same key launches and kills):

```
bind Mod4+Shift+s   exec sh -c 'pkill -x spot || exec spot'
bind Mod4+Shift+d   exec sh -c 'pkill -x spot || exec spot draw'
bind Mod4+Shift+h   exec sh -c 'pkill -x spot || exec spot highlight'
```

First press launches spot; second press kills it. Esc and every other
key passes through to whatever application has focus in **spotlight**
mode — type into the terminal, click in the slides, anything underneath
stays interactive while the spotlight is up.

In **draw** mode, click-drag draws strokes onto a frozen snapshot of the
screen. Configure colour and width via env vars:

```
bind Mod4+Shift+d   exec sh -c 'pkill -x spot || env SPOT_COLOR=00cc44 SPOT_WIDTH=5 exec spot draw'
```

| Env | Default | Effect |
|-----|---------|--------|
| `SPOT_DIM`   | `80`     | spotlight surround brightness (0-100) |
| `SPOT_COLOR` | `ff0000` | draw stroke colour (hex `RRGGBB`, optional `#`) |
| `SPOT_WIDTH` | `3`      | draw stroke width in pixels |

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

- **Snapshot pipeline**, shared by all three modes: `XGetImage` on root
  at startup, walk every pixel through a 256-byte LUT that scales each
  R/G/B channel by `(100 - SPOT_DIM) / 100`, `PutImage` the result into
  a server-side pixmap. That pixmap becomes the overlay's
  `CW_BACK_PIXMAP`, so the X server paints the surround for free.
- **Override-redirect InputOutput window** covers the root. No window
  manager involvement, no focus changes.
- **Spotlight**: SHAPE input region empty (clicks pass through), SHAPE
  bounding region = ~564 per-row rectangles approximating a circle of
  radius 140 px. A precomputed `circle_hw[]` table holds the horizontal
  half-width per row (built in ~140 iterations at startup, then static).
  Cursor tracking polls `XQueryPointer` at 30 Hz; on actual motion one
  `SHAPE Rectangles` request rewrites the bound. Still cursor = zero
  requests, zero CPU.
- **Draw**: GC on the pixmap with the user's colour, line-width, round
  caps + joins. ButtonPress records the stroke origin; each Motion
  event sends a `PolyLine` onto the pixmap and a `ClearArea` over the
  segment's bounding box (padded for the round caps) to refresh just
  that slice of the window.
- **Highlight**: same pixmap, no input pass-through (we own the
  pointer). Drag rectangles trigger four-rect SHAPE bounding updates —
  top, bottom, left, right bars around the user's hole, live as you
  drag.
- **No keyboard grab.** Every key passes through to the focused
  application underneath. The launch keybinding doubles as a kill —
  `pkill -x spot || exec spot ...` toggles cleanly.

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
