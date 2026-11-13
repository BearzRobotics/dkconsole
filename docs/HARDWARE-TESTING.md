# Testing dkconsole on real hardware

dkconsole has only been run in QEMU (`scripts/qemu-console-test/run`). This is how to try it
on a real machine without risking being locked out, and what to send back.

## Before you start

1. **Keep a way in that does not depend on dkconsole.** Either leave a stock `agetty` on
   another VT (say tty6) or have SSH working from a second machine. If the machine is remote,
   do not skip this.
2. Know the VT keys: Ctrl+Alt+F1..F6 switch VT (on a laptop you may need Fn). dkconsole does
   not change that.
3. Build a static binary and copy it over:

   ```
   zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
   sudo install -m 755 zig-out/bin/dkconsole /usr/local/bin/dkconsole
   sudo install -D -m 644 data/config.example.toml /usr/share/dkconsole/config.example.toml
   dkconsole version
   ```

4. Look at what the display driver offers before running anything:

   ```
   sudo dkconsole report
   ```

   It lists each `/dev/dri/cardN`, its driver, every connector (`HDMI-A-1`, `eDP-1`, ...) and
   every mode. It does not start a console or take the display.

## First run: one VT, started by hand

Use a VT you are not on, so a failure cannot take your session with it. From an SSH session, or
from a root shell on another VT:

```
sudo dkconsole --vt 5
```

Press Ctrl+Alt+F5. You should see the banner (`/etc/issue`) and a `login:` prompt. The console
logs to standard error, so the terminal you started it from shows what it is doing. Stop it with
Ctrl+C (SIGINT); it restores the VT's text mode when it exits.

Once that works, run it under your init system on a spare VT: `data/dinit.d/`,
`data/systemd/dkconsole@.service` or `data/sysvinit/inittab-dkconsole`. Try
`systemctl start dkconsole@5` before you `enable` anything, and leave tty1 on its old getty until
you trust it.

## What to check

Tick these off and note anything that is not as described. Details matter more than the
verdict: "screen went black for 3 s then came back" is more useful than "VT switch broken".

| # | Check | Expected |
|---|-------|----------|
| 1 | Banner and prompt appear | `/etc/issue` text with escapes expanded, then `login:` |
| 2 | Log in, run `ls`, `top`, an editor | Output is correct, no stray characters, colors work |
| 3 | Text size | Readable at the screen's native size; `font-size`, `scale`, `font` change it live |
| 4 | Resolution | Native resolution by default; `dkconsole config set mode 1920x1080` switches live |
| 5 | Several monitors | The first connected one is used; `display = "DP-2"` picks another |
| 6 | Keyboard | Layout matches the system's (`loadkeys`/kbd keymap), Shift+PageUp scrolls, key repeat works |
| 7 | Mouse | Selecting text with the mouse and middle-click paste, if used |
| 8 | VT switch away and back | Screen returns intact, input still works; no flicker loop |
| 9 | Another VT running a compositor (labwc/seatd, Xorg) | Compositor starts, and Ctrl+Alt+F-key brings dkconsole back |
| 10 | Log out | Screen is cleared, banner shown again, a fresh `login:` |
| 11 | Suspend and resume (laptops) | Console is visible after resume |
| 12 | Display hotplug | Unplug and replug the monitor, then switch VT away and back |
| 13 | `kill -9` the console | It restarts; after three crashes in a minute the VT gets agetty |

Check 9 is the one the spec calls a required experiment: launching a compositor from the
console's shell is not guaranteed to work. Note exactly what you ran and what happened.

## Reporting back

Run this **on the machine, after reproducing the problem** (the logs are in `/run`, so they are
gone after a reboot):

```
sudo dkconsole report > dkconsole-report.txt 2>&1
```

It contains the dkconsole version, kernel, the settings in effect and where each came from, every
DRM device with its connectors and modes, input device names, the crash counters, and the tail of
the console's own log for each VT (and the previous run's). Read it before sharing it. It has
the kernel command line and device names but not serial numbers or the host name.

Also useful, if you have them:

- The full log. The console writes one copy to standard error (which your init system keeps:
  `journalctl -u 'dkconsole@*'` under systemd, the dinit log under dinit) and one to
  `/run/dkconsole/ttyN.log` (the previous run is `ttyN.log.1`). Each line is
  `dkconsole[ttyN] [seconds since boot] level(scope): message`; the time is the same clock as
  `dmesg`, so you can line them up.
- `sudo dmesg | grep -iE 'drm|fb|simpledrm|amdgpu|i915|nouveau|vt'` around the time of the failure.
- A photo of the screen when it is wrong. Text on a failed display often says what happened.
- The hardware: GPU and driver (the report has the driver), laptop or desktop, how the monitor
  is connected.

For more detail, set `log-level = "debug"` (applies at once) before reproducing. That adds every
VT switch and each step of taking and releasing the display.

### What to look for in the log

| Log line | Meaning |
|----------|---------|
| `drm: driver amdgpu 3.64.0` ... `drm: connector 399 HDMI-A-1: connected` | What the kernel offers |
| `display: connector 399 (HDMI-A-1), 1360x768@60` | What the console chose |
| `display has no 1920x1080 ... mode; using the default one` | `mode` is not offered by that display |
| `no connected display is named DP-9` | `display` does not match any connector name |
| `acquire: 1360x768@60` | The console took the display (VT came to the front) |
| `no usable display (see the drm lines above); using the plain getty` | Fell back to agetty at start |
| `too many recent crashes` | The three-start latch triggered |
| `login started: /bin/login, pid N` | Login is running |

## If the console will not start, or keeps failing

Switch to your spare VT or SSH in, then:

```
sudo dkconsole recovery status              # crash counter per VT
sudo dkconsole recovery reset --vt 5        # clear it (root); a running console is not touched
```

After three starts inside a minute, a VT goes to agetty and stays there until the counter is
cleared or you reboot. `dkconsole report` shows the counters too.

To put the VT back as it was, stop the service (`systemctl stop dkconsole@5`) and start your
usual getty. If a VT is stuck on a blank screen with no keyboard, Ctrl+Alt+F-key to another VT
and the console restores text mode when it is stopped.

## Settings that matter on real hardware

All are in `/etc/dkconsole/config.toml`; `dkconsole config list` shows what is in effect and
`data/config.example.toml` documents each one.

- `mode = "1920x1080"` or `"1920x1080@60"`: some TVs and monitors prefer a lower mode than the
  panel's. `dkconsole report` lists every mode. Applies at once.
- `display = "HDMI-A-1"`: which connector to use on a multi-monitor machine.
- `font`, `font-size`, `scale`: for high-DPI screens use `font-size = 32` or `scale = 2`.
- `issue-file`, `login-program`: the banner and the login binary.
- `log-level = "debug"`: for a bug report.
