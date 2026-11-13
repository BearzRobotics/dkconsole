# dkconsole

A text console for Linux virtual terminals that replaces `agetty`: it draws a login prompt
on the display (KMS/DRM, no X or Wayland), reads the keyboard from evdev, runs the login
program on a pseudo-terminal and shows its output with a real terminal emulator
(DKTermCore, on libghostty-vt). If it cannot start, or crashes three times in a row, it
hands the VT to a plain text getty.

DKConsole is independent of the DKDE desktop. It builds with Zig 0.17.1 and no system libraries.
The specification is `ai/DKCONSOLE-SPEC.md`.

```
zig build                                   # zig-out/bin/dkconsole
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe    # static, for a rescue system
zig build test
```

## Running

`dkconsole --vt N` runs one console on VT N; init-system examples are in `data/`
(`dinit.d/dkconsole@`, `systemd/dkconsole@.service`, `sysvinit/inittab-dkconsole`).
Keep an independent rescue getty on another VT.

## Configuration

TOML, read with toml-zig: `/etc/dkconsole/config.toml` (`$DKCONSOLE_CONFIG` overrides the path),
with `[console]` for every VT and `[vt.N]` to override keys for one. The shipped defaults and the
meaning of every key are in `data/config.example.toml` (installed to
`share/dkconsole/config.example.toml`). Changes apply to running consoles at once, except
`fallback`. The ones people reach for first: `font`/`font-size`/`scale`, `mode` (a display
resolution such as `1920x1080@60`), `display` (which connector), `issue-file` and `login-program`.

```
dkconsole config list [--vt N]            what is in effect, and where each value comes from
dkconsole config get [--vt N] KEY
dkconsole config set [--vt N] KEY VALUE   checked first; writes nothing if already in effect
dkconsole config reset [--vt N] KEY
dkconsole config fonts                    fonts it can use on this system
```

Writing `config.toml` keeps unknown keys and your comments (toml-zig 0.2.0 or later; comments
inside arrays and inline tables are the one exception). The long commented documentation lives
in `config.example.toml`. A file that is not
valid TOML is ignored and the console keeps working with defaults.

## Diagnostics

```
dkconsole report                          what the console sees, to attach to a bug report
dkconsole recovery status [--vt N]        crash counter: will the next start go to agetty?
dkconsole recovery reset --vt N           clear it (root); does not disturb a running console
dkconsole version
```

The console logs to standard error (your init system's log) and to `/run/dkconsole/ttyN.log`.
`/etc/issue` escapes: `\n \l \s \r \m \v \o \O \d \t \u \U \S \S{VAR} \4 \4{if} \6 \6{if} \e`.
See `docs/HARDWARE-TESTING.md` before trying it on real hardware.

## Testing in QEMU

`scripts/qemu-console-test/run` boots the static console in QEMU (no root, no KVM needed, Debian
or Ubuntu for the kernel and busybox) and checks: login on a DRM display, typing, idle memory,
a TrueType font changed while it runs, VT switching, recovery from `kill -9`, the fallback after
repeated crashes, the fallback when there is no display, `dkconsole report` and a display-mode change while running. Screenshots of each step are kept
in `~/.cache/dkconsole-qemu`.

```
scripts/qemu-console-test/run           # set up if needed, then run every check
```

## Not done

See the spec's open questions: image protocols, launching a Wayland session from the console
(a required experiment, not a supported workflow) and the stable DKTermCore API.

## Status

0.1.0. The QEMU test passes all 17 checks on a Ubuntu 7.0 kernel with a simpledrm display
(`scripts/qemu-console-test/run`). It has not been run on real hardware yet.
