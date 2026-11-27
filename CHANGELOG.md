# Changelog

## 0.3.0

Fixes from an adversarial review of 0.2.0. Uses DKTermCore (dkterm) 0.2.0.

### Behaviour changes
- **`osc52` is off by default.** Programs can no longer set the paste buffer unless you set
  `osc52 = true`.
- `colors` is now `color-scheme`; the old name still works. `cursor-style` is new.
- A config file that cannot be read is no longer treated as empty: `config set` and `reset`
  refuse to change it, and a running console keeps its settings.
- `fallback` must start with an absolute path.
- Only unclean exits count towards the fallback latch. The record moved from `tty<N>.starts` to
  `tty<N>.state` in `/run/dkconsole`, which only root can now read.
- `scrollback-lines` now takes effect. Before, about 480 lines were kept at 160 columns however
  high it was set, so memory use with long histories is higher than before.
- On a touchpad, touching no longer clicks.

### Security
- Logging out now discards the whole session. The paste buffer survived, so someone at the next
  login prompt could paste what the last user had selected; some screen contents and terminal
  state survived too.
- Terminal output can no longer set the paste buffer by default.
- The terminal parser, which runs as root, now has safety checks in safe builds.

### Lockouts and freezes
- A failed display take could leave a blank VT that could not be switched away from. The
  keyboard stays open; the console retries and then runs the fallback getty.
- Stopping could hang with the VT held. The VT is now restored first.
- A panic now restores the VT.
- A failed or repeatedly ending login now leads to the fallback getty.
- A program could freeze the screen with synchronized output; it now times out after 1 s.
- A hung-up terminal no longer spins the CPU.

### Other fixes
- Large pastes are no longer cut short.
- Memory is freed while running.
- Config writes keep the file's mode, owner and symlink; long output is printed whole.
- A TrueType fallback font no longer replaces the main font. Damaged fonts no longer crash or
  hang the console. Combining marks are drawn when a font has them.
- Caps Lock and Num Lock survive VT switches; no stuck keys after unplugging or lost events;
  keypad-only keyboards, F13-F24 and more keys work; both Shift and Ctrl keys work with the mouse.
- A wrong `display` name falls back to the first connected display.
- `image-memory` takes effect; settings reload even if `/etc/dkconsole` was created later.
- Selections that scroll away during a drag are dropped.
- The log no longer stops at 1 MiB, XTVERSION reports the real version, and smaller fixes.

### Tests
All unit tests now run (14 never did). The QEMU suite rebuilds every time and checks more: it
used to pass with live reload disabled.

Not yet run on real hardware. The touchpad, lock-key, hotplug and multi-monitor changes in
particular have not been tried on any.
