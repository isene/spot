# spot - Pure Assembly Presenter Spotlight

<img src="img/spot.svg" align="left" width="150" height="150">

![Version](https://img.shields.io/badge/version-0.1.0-blue)
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

## How it works

- Override-redirect InputOutput window covers the root with a dark-gray
  fill (`#202020`). The X server's free background fill does the painting;
  no per-frame draw calls.
- `SHAPE` extension, kind `Input`, rectangles `{}` → window has no input
  region. All pointer events pass straight through to whatever's
  underneath. You can keep clicking around in your presentation while
  the spotlight is up.
- `SHAPE` extension, kind `Bounding`, four rectangles forming a frame
  around the cursor. The 280×280 square at the pointer is excluded →
  underlying screen shows through.
- Cursor tracking polls `XQueryPointer` at 30 Hz. On actual motion (delta
  ≥ 1 px), a single `SHAPE Rectangles` request rewrites the bounding
  frame. Still cursor = zero requests, zero CPU.

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
