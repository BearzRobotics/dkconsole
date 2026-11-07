# DKConsole — Historical Design Inventory

**Reference only.** The current `DKCONSOLE-SPEC.md` and `DKCONSOLE-REQUIREMENTS.md` supersede any conflicts. This inventory is not evidence of implementation.

## 7. Detailed functional design inherited from the previous DKDE specification

The following requirements are preserved as an **initial design baseline**. References to the former in-tree structure, INI configuration and old build commands are superseded by §§2–6. Hardware/API feasibility, security and the DKTermCore API must be revalidated during implementation.



**Model:** the Linux text console, rebuilt. It replaces `agetty` on a virtual
terminal (VT): it shows a login prompt, runs `login`, and gives the session
the terminal features of `dkterm`. It draws through KMS/DRM, not through
the kernel's framebuffer console.

**Why it exists.** The kernel console only does what VT100-era terminals
did: 16 colours (or 256 at best), one font of at most 512 glyphs, and no
graphics protocols. On a machine without a working desktop, or before one
starts, that's the only terminal there is. fbterm, the usual way around
this, has been unmaintained for over a decade.

**The rule above all others:** the console must work when everything above
it doesn't. It never needs GTK, GLib, a compositor, a session D-Bus, seatd
or udev. When it can't start, the user still gets a login prompt (see
*Fallback*).

#### Dependencies

A program this low in the system depends on as little as possible. The
console's dependencies are, in full:

- **libghostty-vt**, for terminal emulation
- **libc** (musl or glibc), through Zig's standard library
- **The kernel's user-space API**: DRM/KMS, evdev and VT ioctls, inotify,
  and netlink

Everything else is written in this repository, in Zig: the DRM mode
setting, VT handling, input, keymap, font loading and rendering, the
login loop, and the configuration reader. None of those jobs is large, and
each one is a well-documented kernel interface or file format. Doing them
here means the console can't be broken by a library it doesn't need.

**Static linking.** On musl, `dkconsole` is linked statically, like the
other programs a rescue system can't do without (shells, coreutils, dinit).
It keeps working when the shared libraries on the system are damaged.

**libghostty-vt's own dependencies:** Ghostty's build pulls in simdutf and
highway, which are C++, unless it is built with `simd=false`. The console
passes `.simd = false` to the `ghostty` dependency (`build.zig`, `addConsole`),
so it has no C++ code and no C++ runtime. Its parser takes the scalar path
instead of the SIMD one. `dkterm` keeps the default build. The rule is to depend on no more than
necessary, not on nothing.

#### Process model

- **One process per VT.** The init system starts `dkconsole --vt N` on
  each VT where `agetty` would otherwise run. dinit, systemd and SysV init
  service files are in `data/` (see 5.10). For dinit it's one templated
  service, `dkconsole@N`.
- **Login.** The console opens a pty, prints `/etc/issue` (with agetty's
  `\n`, `\l`, `\s`, `\r` and `\m` escapes), and starts `login` in it. When
  `login` exits (the user logged out), it clears the screen and starts it
  again. It never runs a shell itself.
- **Privileges.** It runs as root, as a getty does: `login` needs that, and
  it lets the console open the display and input devices itself. It reads
  configuration only from system paths (see *Configuration*), never from a
  user's home directory.

#### VT handling

The console manages its VT directly through the kernel's VT layer. That
layer is also the protocol every other display program uses, so the
console coexists with labwc under seatd, or any other compositor, on
another VT.

- **Taking the VT:** `VT_SETMODE` with `VT_PROCESS`, so the kernel asks
  before switching away; `KDSETMODE KD_GRAPHICS`, so the kernel stops
  drawing text on it; and `KDSKBMODE K_OFF`, so keystrokes reach only the
  console.
- **Switching:** the console handles Ctrl+Alt+F1…F12 itself and calls
  `VT_ACTIVATE`.
- **Release request** (another VT is about to be shown): drop DRM master,
  close the input devices, free the frame buffers, then acknowledge with
  `VT_RELDISP 1`. The console **acknowledges every release request**, even
  in the middle of a redraw. If it doesn't, the kernel refuses the switch
  and the user can't leave the VT.
- **Acquire** (its VT is shown again): acknowledge with
  `VT_RELDISP VT_ACKACQ`, take DRM master, probe the outputs again, reopen
  the input devices, and redraw.
- **Restoring the VT on exit.** On a normal exit and on SIGTERM, SIGINT and
  SIGHUP, the console sets `KD_TEXT`, `K_UNICODE` and `VT_AUTO` again and
  drops DRM master. SIGKILL and crashes can't be caught, so **every start
  first resets the VT to text mode**, and so does the fallback path before
  it `exec`s agetty. agetty doesn't reset the VT mode itself; without this,
  a crash would leave a blank screen even after the fallback.
- Magic SysRq keeps working in every mode, because the kernel handles it
  before the VT layer.

#### Fallback

The console falls back to a plain text login whenever it can't do its job:

- **At start-up:** no DRM device, or no usable display mode. It resets the
  VT to text mode and `exec`s the fallback getty (`[console] fallback`,
  default `/sbin/agetty --noclear tty%N linux`, with `%N` replaced by the VT
  number). Because it `exec`s, the init system still sees the same process.
  A missing font is not a reason to fall back: a default font is built into
  the program (see *Fonts*).
- **After repeated crashes:** each start writes a counter to
  `/run/dkconsole/ttyN.starts` and clears it once the console has run
  for 60 seconds. On the third start within that window, it goes straight
  to the fallback. A console that crashes in a loop must never lock the
  user out.
- **Kernel messages and panics** are not the console's job. They stay with
  the kernel's own console (fbcon), which takes the screen back when the
  console exits. `dmesg` shows them inside a session.

#### Display

- **KMS directly, through the DRM ioctls** (`DRM_IOCTL_MODE_GETRESOURCES`,
  `GETCONNECTOR`, `CREATE_DUMB`, `MAP_DUMB`, `ADDFB2`, `SETCRTC`,
  `PAGE_FLIP`, and `SET_MASTER`/`DROP_MASTER`), with the structures from
  the kernel's `drm.h` and `drm_mode.h`. No libdrm.
- **CPU rendering** into two dumb buffers, swapped with page flips. The
  flip-done events are read from the DRM file descriptor. No GPU API, so
  the console works with any kernel DRM driver, `simpledrm` included.
- **Outputs:** v1 uses the first connected connector in its preferred mode
  and shows nothing on the others. Outputs are probed again on every VT
  acquire. **Post-v1:** mirror to every output, and react to hotplug
  through the kernel's uevent netlink socket.
- **Damage:** per row, as in `dkterm`. Nothing is redrawn that hasn't
  changed, and an idle console doesn't wake up (see *Low-resource*).

#### Fonts

- **v1: PSF bitmap fonts**, the format of the kernel console's own fonts
  and the kbd package's `consolefonts`. The reader takes PSF2 and PSF1 (the
  older format, 8 pixels wide, 256 or 512 glyphs; the built-in 16-pixel
  Terminus is one). A PSF font is a header, a glyph bitmap array and a
  Unicode table, so the reader is short. Drawing a glyph is copying bits;
  there's no rasterizer. Gzipped fonts (`.psf.gz`) are not read; unpack them
  first.
- **A default font is built in** with `@embedFile`: Terminus at 16, 24 and
  32 pixels. The console therefore always has a font, whatever is on disk.
  Terminus is under the SIL Open Font License, which allows bundling it;
  `third_party/terminus/` holds it with its licence (see 6.5). The files are
  the `Uni3-Terminus` conversions from Debian's console-setup, which cover
  Latin, Greek, Cyrillic and many symbols.
- **Size:** chosen from the output's physical size in its EDID, aiming for
  the same physical size on every screen: the largest built-in size that
  keeps at least 80×24 cells. `[console] font-size` overrides it, and
  `[console] scale` (1 or 2) doubles pixels for very dense screens.
- **Other fonts:** `[console] font` takes the path to a PSF2 file, and
  `[console] fallback-fonts` lists PSF2 files used for characters the main
  font lacks. A character no font has is drawn as a box.
- **TrueType outlines (M9)**, read and rasterized in Zig: `[console] font`
  takes a `.ttf` file as well as a PSF file (the type is told by the file's
  first bytes). The `glyf` outlines come from the same `truetype` module
  `pdf renderer` uses (a standalone TrueType module). Each glyph is filled with exact-area
  anti-aliasing into an 8-bit coverage bitmap the first time it is drawn and
  kept in a cache of at most 2048 glyphs per face. There is no hinting. The
  cell is `font-size` pixels tall (0 chooses as for PSF), as wide as the
  face's "M", and shrinks until 80 columns fit. Bold smears the glyph one pixel
  to the right, as for PSF. A character the face lacks is looked up in
  `fallback-fonts` (PSF or TrueType, centred in the cell), then drawn as a box.
  Only monospace faces make a grid; `config fonts` and the Settings page list
  the monospace ones. OpenType files with CFF outlines are refused.
- **Later, unscheduled:** colour emoji (colour bitmap tables such as
  `CBDT`) and ligatures (the `GSUB` table). Both would be welcome, but
  neither is needed soon, and each is a sizeable piece of work. They get a
  milestone when they're wanted, written in Zig like the rest. Hinting is not planned.

Wide characters and grapheme clusters follow libghostty-vt's cell model.

#### Input

- **evdev directly:** the console opens `/dev/input/event*` itself and
  reads `struct input_event`s. Each device is classified by its
  capabilities (`EVIOCGBIT`): keyboards, relative pointers (mice), and
  absolute pointers (tablets, and touchpads through their single-touch
  `ABS_X`/`ABS_Y` axes). No libinput, libevdev, mtdev or udev.
- **Hotplug:** inotify on `/dev/input`, so a keyboard plugged in later
  works. `devtmpfs` creates the nodes itself, so this doesn't need udev.
- **Key repeat** comes from the kernel (the `value == 2` repeat events),
  so the console needs no repeat timer.
- **Keymap: the kernel's own.** The console reads the keymap loaded with
  `loadkeys` from the kernel (`KDGKBENT`, `KDGKBSENT`, `KDGKBDIACRUC` for
  dead keys) and translates key codes with it. The console then follows
  the system's console keymap with no keymap setting of its own, and no
  xkbcommon or XKB data. Reading it again is cheap, so it's done on every
  VT acquire, and a `loadkeys` run takes effect at the next switch.
- **Key encoding** to the program goes through libghostty-vt, as in
  `dkterm`, including the Kitty keyboard protocol.
- **Mouse:** the pointer is drawn only once the mouse moves, and hides
  again on the next key press. Programs that ask for mouse reporting get
  it. Otherwise, dragging selects text.
- **Selection and paste** work within one console: selecting copies, and
  Shift+Insert and the middle button paste. OSC 52 writes go to the same
  buffer. There's no clipboard shared between VTs or with the desktop.

#### Terminal features (v1)

The same libghostty-vt core as `dkterm` (5.3), and the same features
wherever they make sense without a window:

- 24-bit colour, Kitty keyboard protocol, mouse reporting (SGR mode),
  bracketed paste, synchronized output
- Scrollback (Shift+PageUp/PageDown), with `[console] scrollback-lines`
  (default 2000, lower than `dkterm` to keep memory small)
- The colour schemes from 5.3 (`[console] colors`, default `campbell`)
- OSC 8 hyperlinks are shown, but there's nothing to open them with
- Not applicable: window titles (OSC 0/2), tabs, focus events, opacity

**Images (kitty graphics protocol)** are the main reason this console
exists beside fbcon, so they're milestone M10. They depend on what
libghostty-vt exposes, the same open point as 5.3. Image data is decoded
with the PNG and raw RGB(A) formats the protocol requires; a separately declared image-decoding dependency (to be selected) does the PNG decoding, so no system image library is added.
Image memory per console is capped by `[console] image-memory` (default
32 MB), and the oldest images are evicted first.

#### Configuration

The console starts before anyone logs in, so its settings are
system-wide: an exception to 6.1's per-user files.

- **File:** `/etc/dkconsole/config.toml`. Defaults with a comment for every key
  are in `$PREFIX/share/dkconsole/config.example.toml`, and `/etc` holds only what was
  changed, as in 6.1.
- **Format:** TOML, parsed with `toml-zig` (DKC-044; the former `termcore.ini` reader is gone). DKConsole does not use GLib or DKDE configuration modules.
- **Sections:** `[console]` for everything above. `[vt."N"]` overrides keys
  for one VT, for example a larger font on `tty1` only.
- **Changes apply live:** the console watches the file with inotify. Fonts
  and colours change on the next frame. `fallback` takes effect the next
  time the console starts.
- **Missing or invalid values** fall back to the default with a warning,
  never a crash (6.1). An invalid file is not a reason to fall back to
  agetty.

#### Logging

The console writes to standard error, which the init system collects (dinit's
log, the journal, a serial console). Each line has the VT, the time since boot
as in `dmesg`, the level and the part: `dkconsole[tty1] [    12.345] info(drm): ...`.
`[console] log-level` (`error`, `warn`, `info` (default), `debug`) sets how
much, and applies at once. `info` records what was set up (the display and its
mode, the font and the grid, each input device, the login and every restart of
it, a changed configuration file) and every problem, including each setting
that is ignored because its value is invalid and each step that leaves the screen
blank. `debug` adds VT take, release and acquire, keymap reads and font loads.
The fallback to agetty always logs why.

#### Configuration tools

There are two front ends to the same file, so they can never disagree:

- **`dkconsole config`**, a text tool, because the console matters most
  when there's no GUI:
  - `dkconsole config list` shows every key, its value and where it came
    from (default, `/etc`, or `[vt."N"]`).
  - `dkconsole config get KEY`
  - `dkconsole config set [--vt N] KEY VALUE` validates the value before
    writing: a font file must exist and load, and a colour scheme must
    exist.
  - `dkconsole config reset [--vt N] KEY` removes the key, so the
    default applies again.
  - `dkconsole config fonts` lists the built-in fonts and the PSF2 files
    found in the usual console-font directories.

  It follows 6.1's static-files rule: setting a value that's already in
  effect writes nothing. It needs root to write and says so plainly when
  run without it.

  The keymap is set with `loadkeys` as on any Linux console, not with this
  tool (see *Input*).
- **A Console page in `DKDE Settings`** (5.5): font, size, colour scheme
  and scrollback, with a live preview drawn by the console's own renderer
  code (`src/sample.zig`, shared as the `consolefont` module). It
  never writes `/etc` itself. **Apply** asks for the password with the
  elevation dialog the Users page uses and runs `dkconsole config set …`
  for each value, so the console's own validation applies.


