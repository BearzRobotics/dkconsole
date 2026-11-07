# DKConsole — Requirements

**Status:** Consolidated requirements 1.0 (2026-11-04). **Source of implementation detail:** `DKCONSOLE-SPEC.md`; the spec governs architecture and interfaces, while this file contains verifiable outcomes. Engineering rules: `ai/AGENT.md`.

## 1. Scope and independence

- **DKC-001 (MUST):** DKConsole builds and runs without DKDE, DKTerm, GTK, GLib, Wayland, D-Bus, logind, seatd or udev.
- **DKC-002 (MUST):** DKConsole uses independently maintained DKTermCore for terminal emulation, without importing frontend code.
- **DKC-003 (MUST):** The reference target supports musl and glibc; verify static linking for the musl release build.

## 2. Login lifecycle

- **DKC-010 (MUST):** On the graphical path, render `/etc/issue` once before each login attempt; a missing file must not block login.
- **DKC-011 (MUST):** Launch the system `login` executable without a prefilled username. `login`, not DKConsole, displays the username and password prompts.
- **DKC-012 (MUST):** Do not implement PAM, password verification, shadow-file handling or account management.
- **DKC-013 (MUST):** Create a PTY and correctly establish the child's session, controlling terminal, standard streams, environment, terminal size and descriptor isolation.
- **DKC-014 (MUST):** On logout, reap children, erase user-visible and buffered terminal data, display the banner again and restart `login`.
- **DKC-015 (MUST):** Validate login/session behavior, including `tty`, `who` where supported, shell startup, exit status, signal handling and account policy, on the supported login implementations.

## 3. Recovery and fallback

- **DKC-020 (MUST):** On unavailable DRM, unusable display mode or fatal startup initialization failure, restore the kernel text VT and execute a configured getty directly.
- **DKC-021 (MUST):** Track unexpected failures per VT in a rolling 60-second window; the third failure latches text fallback for that VT.
- **DKC-022 (MUST):** The latch persists for the remainder of the boot unless explicitly reset by an administrator. A fallback getty surviving 60 seconds must not reset it.
- **DKC-023 (MUST):** Detect unclean exits across process restarts with a root-owned in-progress marker, including `SIGKILL` where feasible; do not count intentional stops or session logout as failures.
- **DKC-024 (MUST):** Before `execve` of fallback getty, release graphics/input resources and restore `KD_TEXT`, keyboard mode and `VT_AUTO` as appropriate.
- **DKC-025 (MUST):** The default fallback is `/sbin/agetty --noclear tty%N linux`; `%N` is expanded as a VT number without shell evaluation.
- **DKC-026 (MUST):** Provide root-only `dkconsole recovery reset --vt N` and readable `dkconsole recovery status --vt N` commands.
- **DKC-027 (MUST):** A failed fallback exec emits a clear diagnostic and exits; init service restart limits and an independently configured rescue getty must be documented and tested.

## 4. VT, display and input

- **DKC-030 (MUST):** Acquire and release VTs without trapping the user; on release stop input, relinquish DRM master and acknowledge switching; on acquire reinitialize and redraw.
- **DKC-031 (MUST):** Render via Linux DRM/KMS without requiring a compositor; ship an embedded fallback font.
- **DKC-032 (MUST):** Support evdev keyboard input and the system console keymap, including input-device reconnect; verify against representative hardware.
- **DKC-033 (MUST):** Restore usable text mode after orderly termination and on the next launch after an unclean exit where possible.

## 5. Configuration and security

- **DKC-040 (MUST):** Use system-owned `/etc/dkconsole/config.toml` with per-VT overrides; do not load untrusted home-directory configuration before login.
- **DKC-041 (MUST):** Validate configuration, write atomically, and use safe defaults or last known-good runtime settings for malformed input.
- **DKC-044 (MUST):** Parse and write TOML with `toml-zig` (`~/de/toml-zig`, pinned in `build.zig.zon`). No INI reader, no GLib/GKeyFile and no DKDE configuration module. Frontend-neutral terminal keys (`color-scheme`, `cursor-style`, `scrollback-lines`, `osc52`, `command`, `directory`) are read through `termcore.options` from DKTermCore, which uses the same `toml-zig`.
- **DKC-042 (MUST):** Never invoke `sh -c` for configured login/getty commands, and never log passwords, keystrokes or terminal escape payloads.
- **DKC-043 (MUST):** Bound memory for scrollback, escape sequences, clipboard and images; malformed terminal data must not break the login screen.

## 6. Test gates

- **DKC-050 (MUST):** Automated tests cover missing DRM, invalid configuration, absent external fonts, three unexpected failures, fallback latch, explicit reset and failed fallback exec.
- **DKC-051 (MUST):** QEMU tests cover login/logout, VT switching, crash/restart and fallback, with a separate rescue VT.
- **DKC-052 (MUST):** Real-hardware tests cover at least one musl and one glibc installation before production-ready designation.
- **DKC-053 (SHOULD):** Idle resource consumption is measured and reported; provisional target is under 8 MiB RSS per VT, not yet a release gate.

## 7. Open verification items

1. Confirm the actual `login` binary and compatible invocation on FenrirOS and the glibc reference system.
2. Confirm banner escape handling and session accounting expectations with the chosen `login` implementations.
3. Test DRM master handoff, input keymap behavior and recovery after abnormal termination on hardware.
4. Confirm the pinned DKTermCore API supports the required terminal behaviors.

**Requirement levels:** MUST = release gate; SHOULD = target that may be deferred with documented justification. Features such as TrueType fonts and Kitty graphics remain milestone-specific in the specification rather than requirements for the initial usable console.

## 8. Graphical-session coexistence

- **DKC-060 (MUST):** DKConsole runs without seatd, libseat or labwc installed, and does not start or authenticate graphical sessions.
- **DKC-061 (MUST):** A separate labwc/seatd session on another VT can acquire and relinquish display/input access while DKConsole remains alive; returning to DKConsole restores usable display and input.
- **DKC-062 (MUST TEST, NOT GUARANTEED CAPABILITY):** Attempt launching labwc from an authenticated DKConsole PTY shell on FenrirOS. Record controlling-terminal, seatd/libseat, VT and permission behavior. Failure is documented; it does not automatically justify adding a session launcher to DKConsole.
- **DKC-063 (MUST):** Failure or exit of a graphical session does not terminate DKConsole or prevent a console login.

## 9. Additional session and safety tests

- **DKC-070 (MUST):** `login` receives a new session and PTY controlling terminal; privileged parent file descriptors are not inherited; `TERM` matches an installed terminfo entry.
- **DKC-071 (MUST):** `/etc/issue` is shown exactly once before each graphical login; DKConsole never requests a username or password itself.
- **DKC-072 (MUST):** Unexpected `login` exec failure is diagnosed and rate-limited; it must not produce an uncontrolled fork/exec loop.
- **DKC-073 (MUST):** Logout removes previous-session scrollback, selection, clipboard and screen content before a new prompt.
- **DKC-074 (MUST):** Each crash is counted at most once, across a restart, and a stale marker is scoped to the current boot; fallback latch survives successful fallback getty uptime.
- **DKC-075 (MUST):** Preserve an independent rescue VT in deployment instructions; do not promise recovery from failures of the kernel or fallback binary.

## 10. Document authority

This requirements file provides testable acceptance criteria. `DKCONSOLE-SPEC.md` defines design and implementation contracts. `DKCONSOLE-LEGACY-REQUIREMENTS.md` is historical reference only. Requirement IDs must remain stable across revisions; changes to adopted behavior require explicit review.
