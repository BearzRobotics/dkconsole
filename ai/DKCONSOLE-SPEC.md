# DKConsole — Specification

**Status:** Consolidated design specification 1.0 (2026-11-04). Design decisions adopted; implementation and platform compatibility remain unverified.

**Engineering foundation:** `ai/AGENT.md` in the DKConsole repository. The historical console design is adapted below; it is not evidence of current implementation.

## 1. Purpose

DKConsole is an independent Linux virtual-terminal (VT) console and login frontend. It replaces `agetty` on configured VTs, presents a login prompt, and uses DKTermCore to offer modern terminal emulation without starting a graphical desktop.

## 2. Independence and project boundaries

- DKConsole has its **own repository**, `build.zig`, `build.zig.zon`, release cycle, tests, documentation and installation targets.
- It does **not** depend on DKDE, DKTerm, GTK, GLib, GIO, Pango, Wayland, labwc, a display server, D-Bus, logind, seatd or udev.
- Its terminal-engine dependency is the separately maintained **DKTermCore**, pinned to a compatible revision. It does not import DKTermCore's consumers.
- DKDE Settings may optionally call DKConsole's stable CLI for configuration. DKConsole must work when DKDE is not installed.
- The console must work on musl and glibc. Static musl linking is the reference build goal.

## 3. Architecture

```text
init (dinit / systemd / SysV)
  └── dkconsole --vt N
        ├── Linux VT / DRM-KMS / evdev
        ├── login process via PTY
        ├── DKTermCore → libghostty-vt
        ├── standalone font renderer
        └── TOML configuration
```

The console owns VT, display, input, login and recovery. DKTermCore owns frontend-neutral terminal state and protocol processing. Do not move DRM, evdev, authentication or system configuration into DKTermCore.

## 4. Safety and recovery invariants

1. Failure to initialize DRM, input or rendering must never permanently prevent a plain text login.
2. Restore kernel VT text mode before executing the fallback getty.
3. Handle VT release/acquire without trapping the user on an inactive console.
4. Recover after an unclean exit by resetting the VT before graphical initialization.
5. Avoid shell-command construction from user-controlled configuration values.
6. DKConsole must never implement PAM, password verification, shadow-file handling, or account management. The system `login` program owns authentication and account/session setup.
7. DKConsole displays `/etc/issue` once before invoking `login`; `login` owns the username and password prompts.
8. Three unexpected DKConsole failures in a rolling 60-second window latch fallback mode for the affected VT until manual reset or reboot.

## 5. Configuration contract (new)

- System file: `/etc/dkconsole/config.toml`.
- Example/defaults: `$PREFIX/share/dkconsole/config.example.toml`.
- TOML is the project-owned configuration format, read and written with `toml-zig` (pinned in `build.zig.zon`). No dependence on DKDE's config reader.
- Global keys live under `[console]`; per-VT overrides under `[vt."1"]`, `[vt."2"]`, etc.
- CLI: `dkconsole config list|get|set|reset|fonts` with `--vt N` for per-VT overrides.
- Configuration changes must be validated; writes must be atomic. Missing/invalid values should fall back to safe defaults with diagnostics.
- Live reload is desirable for fonts, colors and scrollback; fallback/login behavior can apply on next start.
- Migrating historical INI configuration is an explicit, separately tested migration, not implicit parsing.

## 6. Build and acceptance

- `zig build`: standalone console binary.
- `zig build test`: unit and headless integration tests.
- `zig build -Dtarget=x86_64-linux-musl`: reference musl build; verify static linking in CI.
- `zig build -Dtarget=x86_64-linux-gnu`: glibc build.
- No DKDE or GUI dependency is present in the build graph.
- Verify in QEMU with multiple VTs, keyboard switching, login/logout, missing DRM, malformed config and fallback getty.
- Target (subject to measurement): under 8 MiB idle RSS per VT, no idle wakeups with cursor blink disabled, and low total memory at a login prompt.

## 7. Historical design and feature inventory

The original detailed console design is preserved in `DKCONSOLE-LEGACY-REQUIREMENTS.md`, including direct DRM/KMS ioctls, PSF fonts, evdev, terminal protocols, input devices, configuration, logging and optional TrueType/graphics work. It is a design inventory, **not a normative source when it conflicts with this document**. This separation avoids contradictory login, fallback and configuration requirements. Features are adopted only when assigned to a milestone and acceptance test here or in `DKCONSOLE-REQUIREMENTS.md`.

## 8. Engineering verification and unresolved implementation details

- Verify whether direct evdev handling can reliably implement all intended layouts, compose sequences and device hotplug without a userspace keymap library.
- Confirm DRM/KMS master handoff and VT switching across multiple GPUs and compositors; test failure paths first.
- Specify fallback-getty behavior when `agetty` is missing and prevent restart loops.
- Decide whether the first milestone is PSF-only; standalone TrueType rendering and Kitty graphics should remain separate milestones.
- Audit PTY/login session setup (controlling terminal, signals, environment, credentials and session ownership) before calling the login loop production-ready.
- Verify that the pinned DKTermCore exposes all needed keyboard, scrollback and image APIs rather than assuming upstream support.
- Review the security implications of running as root and opening `/dev/input/event*` directly; minimize privileges where feasible.

## 9. Milestone sequence

1. **M1:** standalone repository, DKTermCore integration, CLI, TOML parsing and headless tests.
2. **M2:** VT acquisition/release, DRM dumb-buffer rendering, PSF font, evdev keyboard and a working fallback getty.
3. **M3:** PTY/login loop, terminal modes, resize, scrollback and stable logout/relogin.
4. **M4:** config CLI, live reload, service definitions, multi-VT and failure-injection tests.
5. **M5:** richer font support, pointer/selection, image protocols and optional features after basic recovery is proven.

## 10. Session, device and privilege contracts (proposed)

### 10.1 Login lifecycle

DKConsole is a terminal host, **not** an authenticator. The configured login implementation owns PAM (where applicable), credential checks, supplementary groups, environment policy, account restrictions, utmp/wtmp where supported, and user-session initialization. DKConsole must create a PTY pair, establish the correct controlling terminal and process/session relationship, propagate terminal size, close unneeded file descriptors, and wait/reap children. Logout clears prior user content and launches a new login prompt; signals and terminal resize are forwarded appropriately. `login` implementations vary across distributions: exact invocation and compatibility must be verified on FenrirOS and at least one glibc distribution before release.

Do not pass user-provided names, prompts or configuration values through `sh -c`. Avoid inheriting privileged environment variables into the login process. Never log passwords, keystrokes, clipboard contents or terminal escape payloads. Root-only device and config access is an implementation baseline, not permission to retain unnecessary capabilities in child processes.

### 10.2 Device ownership and VT handoff

DKConsole owns input and DRM only while its VT is active. On release it stops consuming input, suspends drawing and relinquishes DRM master before acknowledging the switch; on acquire it re-probes resources and redraws. The order of VT mode and keyboard mode changes must be tested against failure at every step. No operation may block a release indefinitely. Handling of DRM leases, multiple GPUs, disconnected monitors and compositor ownership is OPEN until hardware validation.

### 10.3 Security limits for escape sequences

Terminal control sequences are untrusted input. Bound memory used by scrollback, image payloads, string escape sequences, hyperlinks and clipboard requests. Define explicit behavior for OSC 52, mouse reporting and image protocols, with defaults appropriate for a login console. Reject malformed sequences without losing the login prompt. Fuzz parser-facing integration boundaries in addition to DKTermCore's own tests.

## 11. Fallback and recovery state machine (proposed)

```text
START → reset VT to known text state → load/validate config
  → acquire VT and probe DRM/input → initialize renderer → LOGIN
  ├─ recoverable error: log, release resources, retry only with bounded policy
  └─ unrecoverable error: restore text VT → exec fallback getty
LOGIN → session exit → clear sensitive screen/scrollback → LOGIN
VT release → stop input/render → release DRM → acknowledge → WAIT
WAIT → VT acquire → re-probe/reacquire → redraw → LOGIN
```

The third-start crash safeguard is **required**, not optional, and is not a substitute for init-system restart limits. Use atomic, root-owned state under `/run/dkconsole/`; protect against stale state after reboot. If fallback getty is absent, attempt a documented emergency text-login path only if secure and feasible; otherwise exit with a clear diagnostic and rely on a separately configured rescue VT. **A separate known-good getty VT is required during deployment and early testing** so that failure of the DKConsole binary cannot lock out the administrator. A program cannot guarantee recovery from kernel, driver or total storage failure.

Test each initialization stage with injected failures and verify that the kernel text console is restored where possible. Verify `SIGTERM`, abrupt kill followed by restart, failed KMS mode set, missing keyboard, removed input device, logout/relogin and switching repeatedly between graphical and text VTs.

## 12. Configuration schema and CLI semantics (proposed)

System-owned TOML under `/etc/dkconsole/config.toml` is authoritative; per-VT tables override global settings. Configuration is never loaded from an untrusted user's home directory before authentication. Preserve comments/unknown keys when practical; `config set` must not silently erase unrelated settings. Atomic replacement must preserve secure file permissions and ownership. A full invalid TOML document should retain the last known-good running configuration rather than partially applying it.

Illustrative schema (names and defaults to be finalized):

```toml
[console]
font = "builtin:terminus-16"
scrollback_lines = 2000
color_scheme = "campbell"
image_memory_mib = 32
fallback_program = "/sbin/agetty"

[vt."2"]
font = "builtin:terminus-24"
```

CLI operations must have stable exit codes: `0` success; nonzero for invalid key/value, permission denied, missing file/font or failed write. `config get` prints a machine-readable value without decorative text; `config list` may be human-readable. Introduce `config validate [--file PATH]` and `config dump-effective [--vt N]` for testing and administration. Any operation that changes `/etc` requires root or an explicitly authorized privileged helper; never elevate silently.

## 13. Build, packaging and deployment (proposed)

- Build only DKConsole and DKTermCore; no DKDE source, toolkit or desktop library in the build graph.
- Ship `dkconsole`, sample TOML, man page, license notices, optional service examples and required embedded font assets.
- Provide dinit as the reference service integration. systemd/SysV service examples may be supplied but are not runtime dependencies.
- Install services **disabled by default**. Enabling a DKConsole VT must not conflict with an existing getty or compositor assigned to that VT.
- Document safe rollback: disable DKConsole service, restore previous getty, and verify a rescue login before removing the old service.
- Verify static musl linking rather than assuming it from a target triple; inspect produced binaries and transitive libraries.

## 14. Acceptance tests and milestone gates (proposed)

| Test | Required outcome |
|---|---|
| No DRM device | clean fallback to kernel text/getty, with diagnostic |
| Invalid or missing TOML | safe defaults or last known-good settings; no crash |
| Missing external font | embedded font loads |
| Repeated process crashes | bounded restart/fallback, rescue VT remains available |
| VT switch under output load | switch completes; reacquire redraws correctly |
| Login and logout | correct controlling terminal, privileges and clean prompt reset |
| Hotplug keyboard/mouse | no stuck keys; usable input after reconnection |
| Multiple VTs | isolated scrollback, input, and login sessions |
| Malformed escape/image data | bounded memory, no crash or credential leak |
| musl and glibc builds | standalone binaries link without desktop dependencies |

M1/M2 must pass headless and QEMU tests before real hardware deployment. M3 is gated on a login/session security audit; M4 on crash recovery and multi-VT tests; optional fonts and image support cannot delay a working safe text login. Performance targets (including the provisional 8 MiB idle RSS) require measurements on representative hardware and are not hard pass/fail requirements yet.

## 15. Remaining engineering verification

1. Verify the exact `login` executable, flags, PAM/session policy, and `/etc/issue` escape compatibility on FenrirOS; the responsibility split is decided.
2. Whether direct evdev and kernel keymaps cover the desired input languages and modifiers.
3. A safe DRM/KMS and VT master-handoff strategy across multiple GPUs.
4. Whether OSC 52 and terminal graphics are enabled at the login prompt or only after login.
5. Whether DKTermCore exposes a sufficiently stable frontend-neutral API for all required operations.
6. First-release scope: PSF-only versus TrueType and image protocol milestones.
7. What is guaranteed when the configured fallback getty does not exist; a separate rescue VT remains mandatory.


## 16. Adopted login and fallback contract (normative)

### 16.1 Login presentation and authentication

- DKConsole renders `/etc/issue` on its terminal before each fresh login. It supports the documented subset of traditional agetty escapes (`\n`, `\l`, `\s`, `\r`, `\m`), with unknown escapes treated safely. A missing `/etc/issue` is nonfatal. DKConsole **does not prompt for a username**.
- DKConsole launches the system `login` program **without a pre-supplied username** on a correctly established PTY controlling terminal. `login` prints the username prompt, performs password authentication and policy checks, and starts the user's session and login shell. The selected implementation must be verified to support this invocation. Do not use `login -f`, `login -p`, or other authentication-bypassing flags.
- DKConsole does not link PAM, read `/etc/shadow`, verify passwords, or manage accounts. A system login implementation may itself depend on PAM or a session manager; this is outside DKConsole's dependency contract.
- After the login session ends, DKConsole reaps children, clears screen, scrollback and selection/clipboard buffers (including any password-adjacent state), displays `/etc/issue` again, and launches a fresh `login` process. Never print the issue banner twice; DKConsole owns it on the graphical path, while `agetty` owns it in fallback mode.
- The child must run in a new session with the PTY slave as controlling terminal, correct standard streams, window size, terminal environment and closed inherited privileged descriptors. DKConsole retains the PTY master and remains the rendering host. Verify `login` behavior, session accounting, signals, and `tty`/`who` on musl and glibc reference systems.

### 16.2 Failure counter and latched fallback

- Keep root-owned per-VT recovery state in `/run/dkconsole/` (mode 0700 directory; files not writable by ordinary users). State is per VT, never shared across all consoles. The runtime directory is cleared on reboot; include the boot ID when needed to reject stale state.
- Count **unexpected process failures** within a rolling 60-second window, including startup crashes and abnormal termination. An orderly logout of the user session, an intentional service stop, or a deliberate restart for configuration must not count as a crash. A successful run lasting 60 seconds may age earlier events out of the rolling window, but does not clear a latched fallback.
- Because a process killed by `SIGKILL` cannot record its own exit, each launch must first inspect the preceding launch's durable *in-progress* marker, and then atomically record the new launch. A clean exit clears its marker. For precise failure classification, the init supervisor's exit status may be used where available; otherwise an unclean marker is conservatively treated as an unexpected failure. Do not count a new launch twice for the same failure.
- On the **third unexpected failure within 60 seconds**, write an atomic, durable-for-this-boot fallback latch for that VT. Subsequent starts bypass DRM and DKTermCore initialization and proceed directly to the text getty, regardless of whether 60 seconds have elapsed. A long-running fallback getty does **not** clear the latch.
- The latch is cleared only by reboot or an explicit administrator command, `dkconsole recovery reset --vt N`. This command must require root and must not interrupt an active login. `dkconsole recovery status --vt N` reports the state and recent failures.
- For startup failures that DKConsole can detect without crashing (missing DRM device, no usable mode, fatal renderer/input initialization error), restore the text console and immediately enter fallback; do not intentionally crash three times first. A failure during a later running session should likewise restore the VT and enter fallback when safe; the failure history protects against crashes where cleanup cannot run.
- **Fallback handoff order:** stop input/rendering; release DRM resources/master; restore VT text mode (`KD_TEXT`), kernel keyboard mode and automatic VT switching; close sensitive descriptors; then `execve` the configured fallback getty with an argument vector (never through a shell). Default executable `/sbin/agetty`, default arguments `--noclear tty%N linux` with `%N` expanded to the numeric VT. Resolve the executable and argument-vector configuration securely, with no shell interpolation.
- If fallback `execve` fails, report the error to the service log, restore the text VT as far as possible and exit nonzero. The init configuration must impose restart limits, and installation must preserve an independently configured rescue getty VT. DKConsole cannot guarantee access if both it and the fallback executable are missing or the kernel console is broken.

### 16.3 Example configuration

```toml
[console]
login_program = "/bin/login"   # packaging may select another verified path
fallback_program = "/sbin/agetty"
fallback_args = ["--noclear", "tty%N", "linux"]
issue_file = "/etc/issue"
crash_window_seconds = 60
crash_threshold = 3
```

The 60-second window and three-failure threshold are normative defaults; whether to expose them as configurable options remains an implementation decision. Reject insecure fallback or login program paths and invalid argument vectors rather than passing them through a shell.

## 17. Wayland compositor and seatd coexistence (adopted)

DKConsole is independent of seatd, libseat, labwc, DKDE and any graphical-session launcher. FenrirOS currently uses seatd/libseat with labwc; DKConsole does not replace or reimplement that arrangement. It must coexist with a compositor on another VT, releasing DRM master and input access when its VT becomes inactive and restoring its own resources on reactivation. Do not assume DRM master release alone is sufficient for every device or backend; test the full handoff.

The authenticated shell is attached to a PTY (`/dev/pts/N`), not directly to the real VT (`/dev/ttyN`). Therefore launching `labwc` directly from that shell is a **required integration experiment**, not a guaranteed supported workflow. Verify actual seatd/libseat behavior, controlling-terminal requirements, VT selection, permissions, return to console and recovery on the reference system. If this fails, document the failure and design a separate launcher only after evidence demonstrates a need. **DKConsole must not acquire responsibility for launching or authenticating Wayland sessions.** A compositor failure must not terminate the console login service.

## 18. PTY and session safety details

- The privileged parent opens and configures the PTY, keeps the master, and never passes DRM, input, root-owned configuration, or recovery-state descriptors into `login` or its descendants. Child descriptor inheritance is allowlisted.
- The child creates a new session, acquires the PTY slave as controlling terminal, attaches stdin/stdout/stderr, establishes window size and signals, and invokes a configured, verified system `login` program with no prefilled username. Handle exec failures by showing a diagnostic and preserving a usable login/recovery path; do not repeatedly spawn an invalid login binary at full speed.
- `TERM` must name an installed, compatible terminfo description. The advertised keyboard and graphics features must match what DKTermCore and the renderer actually implement. Resize updates both the PTY window size and the terminal model.
- DKConsole owns `/etc/issue` rendering on the graphical path; `/bin/login` owns both username and password prompts. The fallback `agetty` owns its own banner. Do not duplicate the banner or collect a username in DKConsole.
- On logout, terminate/reap the entire previous session as appropriate, clear terminal screen, scrollback, selection and clipboard buffers, then create a fresh PTY and launch a new `login`. Do not expose output or secrets from the preceding session.
- `login` and its underlying authentication/session modules may require PAM or other platform services; these are dependencies of the **system login stack**, not direct DKConsole library dependencies. Verify supported login binaries on FenrirOS and glibc Linux before marking production-ready.

## 19. Failure classification and recovery test contract

A normal user logout is not a DKConsole process crash. Clean administrative stops, expected VT switches and deliberate reloads are not failures. An unexpected DKConsole termination, including a stale in-progress marker on next startup, is a failure. The counter uses per-VT monotonic timestamps where available and a boot-scoped latch. On the third unexpected failure within a rolling 60-second interval, bypass graphical startup and `execve` the fallback getty. A detected unusable display/input condition may enter fallback immediately without waiting for three failures. A fallback process remaining alive for 60 seconds never resets the latch.

A root-only recovery reset changes the latch for future starts and must not disrupt an active session. The init service must have bounded restart policy and an independently maintained rescue VT. The recovery guarantee is **best effort**: no user-space application can guarantee recovery if the kernel, VT driver, fallback getty, or init supervisor is unavailable.

## 20. Delivery and document precedence

`DKCONSOLE-REQUIREMENTS.md` defines testable MUST/SHOULD requirements; this document defines architecture, behavior, defaults and milestones. `DKCONSOLE-LEGACY-REQUIREMENTS.md` preserves historical detail for migration and has no authority over conflicting adopted decisions. `ai/AGENT.md` governs engineering conventions. None of these documents assert that the described software is already implemented.
