//! One console on one VT (SPEC.md 5.11): libghostty-vt for the terminal, a pty
//! with `login` in it, the kernel's VT layer, DRM for the screen, evdev for the
//! keyboard and mouse. A single `poll` loop drives all of it, so an idle console
//! sleeps until something happens.

const std = @import("std");
const vt = @import("ghostty-vt");
const termcore = @import("termcore");
const Pty = termcore.pty.Pty;
const config = @import("config.zig");
const configtool = @import("configtool.zig");
const drm = @import("drm.zig");
const evdev = @import("evdev.zig");
const fallback = @import("fallback.zig");
const issue = @import("issue.zig");
const build_options = @import("build_options");
const kbd = @import("kbd.zig");
const psf = @import("psf.zig");
const ttf = @import("ttf.zig");
const render = @import("render.zig");
const sys = @import("sys.zig");
const vtmod = @import("vt.zig");

const log = std.log.scoped(.console);

extern fn poll(fds: [*]evdev.PollFd, n: c_ulong, timeout: c_int) c_int;
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern fn inotify_init1(flags: c_int) c_int;
extern fn inotify_add_watch(fd: c_int, path: [*:0]const u8, mask: u32) c_int;
const Timespec = extern struct { sec: c_long, nsec: c_long };

fn nowSeconds() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return ts.sec;
}

fn nowMs() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(1, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// How long to wait before each further try at taking the display. Another
/// process, our own on another VT included, may still hold it for a moment.
const display_retry_ms = [_]i64{ 100, 200, 400, 800, 1600 };

/// A login that cannot be started, or ends this soon, has failed. After this
/// many failures in a row the VT goes to the fallback getty; between tries the
/// console waits, without blocking.
const quick_login_ms = 2000;
const max_login_failures = 5;
const login_retry_ms = 1000;

/// The longest a program may hold the screen for synchronized output. The
/// terminal has no clock, so ending a hold that is never released is the
/// console's job. Ghostty uses the same second.
const render_hold_ms = 1000;

/// While nothing has the terminal open, its master is always ready to read.
/// It is left out of `poll` this long, then looked at again: a running program
/// can open the terminal again.
const hangup_wait_ms = 100;

const login_paths = [_][:0]const u8{ "/bin/login", "/usr/bin/login", "/sbin/login", "/usr/sbin/login" };

pub const Options = struct { vt: u32 };

pub fn run(allocator: std.mem.Allocator, opts: Options) u8 {
    var c: Console = .{ .allocator = allocator, .vt_num = opts.vt };
    return c.main();
}

const Damage = struct {
    full: bool = true,
    rows: std.ArrayList(bool) = .empty,
};

const FontSet = struct {
    /// Owned file data for fonts read from disk (the built-in ones borrow).
    data: std.ArrayList([]u8) = .empty,
    fonts: std.ArrayList(*psf.Font) = .empty,
    ptrs: std.ArrayList(*const psf.Font) = .empty,
    faces: std.ArrayList(*ttf.Face) = .empty,

    fn deinit(self: *FontSet, a: std.mem.Allocator) void {
        for (self.fonts.items) |f| {
            f.deinit(a);
            a.destroy(f);
        }
        for (self.faces.items) |f| {
            f.deinit();
            a.destroy(f);
        }
        self.faces.deinit(a);
        for (self.data.items) |d| a.free(d);
        self.data.deinit(a);
        self.fonts.deinit(a);
        self.ptrs.deinit(a);
    }

    fn add(self: *FontSet, a: std.mem.Allocator, bytes: []const u8, owned: ?[]u8) !void {
        const f = try a.create(psf.Font);
        errdefer a.destroy(f);
        f.* = try psf.Font.parse(a, bytes);
        errdefer f.deinit(a);
        try self.fonts.append(a, f);
        errdefer _ = self.fonts.pop();
        try self.ptrs.append(a, f);
        errdefer _ = self.ptrs.pop();
        if (owned) |o| try self.data.append(a, o);
    }

    /// A TrueType file: a face `cell_h` pixels tall. The file data is kept
    /// by the font set.
    fn addTrueType(self: *FontSet, a: std.mem.Allocator, bytes: []u8, cell_h: u32) bool {
        const f = a.create(ttf.Face) catch return false;
        f.* = ttf.Face.init(a, bytes, cell_h) catch {
            a.destroy(f);
            return false;
        };
        self.faces.append(a, f) catch {
            f.deinit();
            a.destroy(f);
            return false;
        };
        self.data.append(a, bytes) catch {
            _ = self.faces.pop();
            f.deinit();
            a.destroy(f);
            return false;
        };
        return true;
    }

    /// A PSF or TrueType font file. TrueType gets `cell_h` pixels of height.
    fn addFile(self: *FontSet, a: std.mem.Allocator, path: []const u8, cell_h: u32) bool {
        const bytes = sys.readFile(a, path, 32 << 20) catch |e| {
            log.warn("font {s}: cannot read ({s}); using another", .{ path, @errorName(e) });
            return false;
        };
        if (ttf.looksLikeTrueType(bytes)) {
            if (self.addTrueType(a, bytes, cell_h)) return true;
            log.warn("font {s}: not a usable TrueType font (CFF outlines and damaged files are refused); using another", .{path});
            a.free(bytes);
            return false;
        }
        self.add(a, bytes, bytes) catch |e| {
            log.warn("font {s}: not a PSF or TrueType font ({s}); using another", .{ path, @errorName(e) });
            a.free(bytes);
            return false;
        };
        log.debug("font {s}: loaded as PSF", .{path});
        return true;
    }

    fn addBuiltin(self: *FontSet, a: std.mem.Allocator, height: u32) !void {
        const i: usize = if (height >= 32) 2 else if (height >= 24) 1 else 0;
        try self.add(a, psf.builtin_data[i].data, null);
    }
};

pub const Console = struct {
    allocator: std.mem.Allocator,
    vt_num: u32,

    // settings
    etc: ?*anyopaque = null,
    etc_doc: @import("tomlcfg.zig").Document = undefined,
    defs_doc: @import("tomlcfg.zig").Document = undefined,
    docs_loaded: bool = false,
    settings: config.Settings = undefined,
    conf_watch: c_int = -1,

    // kernel interfaces
    vtdev: vtmod.Vt = undefined,
    sig_fd: c_int = -1,
    dev: ?drm.Device = null,
    out: drm.Output = undefined,
    bufs: [2]?drm.Buffer = .{ null, null },
    /// The buffer to draw into next; the other one is on screen.
    back: u1 = 1,
    flip_pending: bool = false,
    damage: [2]Damage = .{ .{}, .{} },
    have_display: bool = false,
    /// The VT is shown and the keyboard read, but taking the display failed:
    /// how often, and when to try again.
    display_failures: u32 = 0,
    display_retry_at: ?i64 = null,
    /// Hand the VT to the fallback getty once everything is released.
    use_fallback: bool = false,
    /// The keyboard is open: whenever this VT is shown, display or not.
    have_input: bool = false,
    input: evdev.Input = undefined,
    keymap: kbd.Keymap = undefined,
    decoder: kbd.Decoder = undefined,

    // text
    fonts: FontSet = .{},
    renderer: render.Renderer = undefined,
    cols: u16 = 80,
    rows: u16 = 24,
    origin_x: u32 = 0,
    origin_y: u32 = 0,
    scheme: termcore.schemes.Scheme = undefined,

    // terminal
    tiny_io: vt.TinyIo = .init,
    term: vt.Terminal = undefined,
    stream: vt.TerminalStream = undefined,
    state: vt.RenderState = .empty,
    /// While set, the program has asked for the screen to stay as it is.
    hold_until: ?i64 = null,
    pty: Pty = .{ .master = -1, .pid = 0 },
    pty_resume_at: ?i64 = null,
    /// Input the program has not taken yet.
    outbox: termcore.pty.Outbox = .{},
    login_running: bool = false,
    last_cursor: ?struct { x: u16, y: u16 } = null,
    cursor_on: bool = true,
    next_blink: i64 = 0,

    // pointer and selection
    pointer_visible: bool = false,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    pointer_shown_rows: ?[2]u32 = null,
    selecting: bool = false,
    anchor: ?vt.Pin = null,
    primary: std.ArrayList(u8) = .empty,

    /// The fonts changed while this VT was in the background.
    layout_stale: bool = false,
    /// When the running login was started, in ms; 0 before the first.
    login_started_at: i64 = 0,
    login_failures: u32 = 0,
    login_retry_at: ?i64 = null,
    healthy_at: i64 = 0,
    healthy_done: bool = false,
    quit: bool = false,

    // ---- start-up ----------------------------------------------------------------

    fn main(self: *Console) u8 {
        const a = self.allocator;
        sys.log_vt = self.vt_num;
        sys.openLogFile(fallback.state_dir, self.vt_num);
        self.vtdev = vtmod.Vt.open(self.vt_num) orelse {
            log.err("cannot open /dev/tty{d}: errno {d}", .{ self.vt_num, sys.errno() });
            return 1;
        };
        // A crash cannot restore the VT, so every start does (SPEC.md 5.11).
        self.vtdev.restoreText();

        self.loadSettings();
        const starts = fallback.readCounter(a, self.vt_num);
        var uts: issue.Uts = .{};
        const sysinfo = uts.system("");
        log.info("dkconsole {s} on {s} {s} {s}", .{ build_options.version, sysinfo.sysname, sysinfo.release, sysinfo.machine });
        log.info("starting on tty{d}: {d} start(s) in the last {d} s, euid {d}", .{ self.vt_num, starts, fallback.healthy_seconds, std.c.geteuid() });
        const decision = fallback.decide(starts);
        if (decision.fall_back) {
            log.err("too many recent crashes ({d} starts); using the plain getty: {s}", .{ starts, self.settings.fallback });
            fallback.execFallback(a, self.settings.fallback, &self.vtdev);
            return 1;
        }
        if (decision.write_count) |n| fallback.writeCounter(self.vt_num, n);

        self.sig_fd = vtmod.installSignals() orelse blk: {
            log.err("cannot set up signal handling; VT switching and shutdown will not work", .{});
            break :blk -1;
        };

        if (!self.openDisplay()) {
            log.err("no usable display (see the drm lines above); using the plain getty: {s}", .{self.settings.fallback});
            fallback.execFallback(a, self.settings.fallback, &self.vtdev);
            return 1;
        }

        self.input = evdev.Input.init(a);
        self.keymap = kbd.Keymap.init(a);
        self.decoder = kbd.Decoder.init(&self.keymap);

        self.setupTerminal() catch |e| {
            log.err("terminal setup failed ({s}); using the plain getty: {s}", .{ @errorName(e), self.settings.fallback });
            self.closeDisplay();
            fallback.execFallback(a, self.settings.fallback, &self.vtdev);
            return 1;
        };
        self.startLogin();

        if (!self.vtdev.take()) log.err("could not take the VT; running anyway", .{});
        if (self.vtdev.isActive()) {
            self.acquire();
        } else if (self.dev) |*d| {
            // Another VT is on screen. Opening the card made us its master if
            // nobody else was, and a compositor over there must be able to take
            // it, so let go until this VT is shown.
            d.dropMaster();
        }

        self.healthy_at = nowSeconds() + fallback.healthy_seconds;
        self.watchConfig();
        log.info("running: {d}x{d} cells, login {s}", .{ self.cols, self.rows, if (self.login_running) "started" else "NOT running" });
        self.loop();
        log.info("stopping", .{});
        self.shutdown();
        if (self.use_fallback) {
            log.err("using the plain getty: {s}", .{self.settings.fallback});
            fallback.execFallback(a, self.settings.fallback, &self.vtdev);
            return 1;
        }
        self.vtdev.close();
        return 0;
    }

    fn shutdown(self: *Console) void {
        self.releaseDisplayResources();
        self.input.deinit();
        self.keymap.deinit();
        if (self.dev) |*d| d.close();
        // Back to a text console for whoever comes next, and first: ending the
        // login can take a while, and nothing may hold the VT meanwhile.
        self.vtdev.restoreText();
        self.pty.deinit();
        self.outbox.deinit(self.allocator);
    }

    fn loadSettings(self: *Console) void {
        self.reloadDoc(&self.etc_doc, configtool.etcPath());
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        self.reloadDoc(&self.defs_doc, configtool.defaultsPath(&dbuf));
        self.docs_loaded = true;
        self.settings = config.Settings.resolve(.{ .etc = &self.etc_doc, .defaults = &self.defs_doc }, self.vt_num);
        self.scheme = termcore.schemes.scheme(self.settings.colors);
        sys.log_level = sys.parseLevel(self.settings.log_level);
        self.warnInvalidSettings();
        log.info("settings: font='{s}' size={d} scale={d} colors={s} scrollback={d} log-level={s} mode='{s}' display='{s}' issue-file='{s}' login-program='{s}'", .{
            self.settings.font,        self.settings.font_size,        self.settings.scale,
            self.settings.colors,      self.settings.scrollback_lines, self.settings.log_level,
            self.settings.mode_text,   self.settings.display,          self.settings.issue_file,
            self.settings.login_program,
        });
    }

    /// Reads `path` into `doc`. A file that cannot be used changes nothing: the
    /// console keeps the settings it had (at start-up, none).
    fn reloadDoc(self: *Console, doc: *@import("tomlcfg.zig").Document, path: []const u8) void {
        var problem: configtool.Problem = .{};
        if (configtool.loadDoc(self.allocator, path, &problem)) |fresh| {
            if (self.docs_loaded) doc.deinit();
            doc.* = fresh;
        } else |_| {
            log.warn("{s}: {s}; {s}", .{ path, problem.text(), if (self.docs_loaded) "keeping the settings in use" else "ignoring the file" });
            if (!self.docs_loaded) doc.* = .init(self.allocator);
        }
    }

    /// A value that fails its check is skipped (a typo must never break the
    /// console), so say which one and why, where the administrator will see it.
    fn warnInvalidSettings(self: *Console) void {
        var gbuf: [24]u8 = undefined;
        const vt_group = std.fmt.bufPrint(&gbuf, "vt:{d}", .{self.vt_num}) catch "";
        for ([_][]const u8{ config.group, vt_group }) |g| {
            for (&config.keys) |*k| {
                const v = self.etc_doc.get(g, k.name) orelse continue;
                if (config.check(k, v)) |why| log.warn("{s}: [{s}] {s}={s} is ignored: {s}", .{ configtool.etcPath(), g, k.name, v, why });
            }
        }
    }

    fn watchConfig(self: *Console) void {
        const path = configtool.etcPath();
        const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else ".";
        var b: [std.fs.max_path_bytes]u8 = undefined;
        const z = sys.pathZ(&b, dir) orelse return;
        self.conf_watch = inotify_init1(sys.O_CLOEXEC | sys.O_NONBLOCK);
        if (self.conf_watch < 0) return;
        // IN_CLOSE_WRITE | IN_MOVED_TO: the tool writes through a rename.
        if (inotify_add_watch(self.conf_watch, z.ptr, 0x8 | 0x80) < 0) {
            _ = sys.close(self.conf_watch);
            self.conf_watch = -1;
        }
    }

    // ---- display -------------------------------------------------------------------

    fn openDisplay(self: *Console) bool {
        var d = drm.Device.openFirst(self.allocator) catch |e| {
            log.err("no DRM device usable: {s}", .{@errorName(e)});
            return false;
        };
        d.want = self.settings.mode;
        d.setDisplay(self.settings.display);
        self.logDisplays(&d);
        const out = d.probe(self.allocator) catch |e| {
            log.err("no connected display: {s}", .{@errorName(e)});
            d.close();
            return false;
        };
        var nb: [32]u8 = undefined;
        log.info("display: connector {d} ({s}), {d}x{d}@{d}, {d}x{d} mm", .{
            out.connector_id,  drm.connectorName(&nb, out.connector_type, out.connector_type_id), out.width(), out.height(), out.mode.vrefresh,
            out.mm_width, out.mm_height,
        });
        self.dev = d;
        self.out = out;
        self.buildLayout() catch {
            d.close();
            self.dev = null;
            return false;
        };
        return true;
    }

    /// Everything the driver reports, one log line each, so a report from a
    /// machine says what the display could do and not only what was chosen.
    fn logDisplays(self: *Console, d: *drm.Device) void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        d.describe(self.allocator, &aw.writer) catch return;
        var it = std.mem.splitScalar(u8, aw.written(), '\n');
        while (it.next()) |l| if (l.len > 0) log.info("drm: {s}", .{l});
    }

    fn closeDisplay(self: *Console) void {
        if (self.dev) |*d| d.close();
        self.dev = null;
    }

    /// Fonts, then the grid that fits the screen.
    fn buildLayout(self: *Console) !void {
        const a = self.allocator;
        var set: FontSet = .{};
        errdefer set.deinit(a);

        var h = self.settings.font_size * self.settings.scale;
        if (h == 0) h = drm.chooseFontHeight(self.out.width(), self.out.height(), self.out.mm_height) * self.settings.scale;
        var main_ok = false;
        var builtin_height: ?u32 = null;
        // `config fonts` lists the built-in fonts by name: terminus-16, -24 and -32.
        for (psf.builtin_data) |b| {
            if (std.mem.eql(u8, b.name, self.settings.font)) builtin_height = std.fmt.parseInt(u32, b.name["terminus-".len..], 10) catch null;
        }
        if (builtin_height == null and self.settings.font.len > 0) main_ok = set.addFile(a, self.settings.font, h);
        // A TrueType cell is not half as wide as it is tall: shrink until 80 columns fit.
        if (main_ok and set.faces.items.len > 0) {
            const face = set.faces.items[0];
            const wanted = h;
            while (face.cell_h > 8 and self.out.width() / face.cell_w < 80) face.resize(face.cell_h - 1);
            h = face.cell_h;
            if (h != wanted) log.info("font size {d} is too large for 80 columns on this screen; using {d}", .{ wanted, h });
        }
        if (!main_ok) try set.addBuiltin(a, builtin_height orelse if (self.settings.font_size == 0) h / self.settings.scale else self.settings.font_size);
        var it = std.mem.tokenizeAny(u8, self.settings.fallback_fonts, ", ");
        while (it.next()) |path| _ = set.addFile(a, path, h);
        // The built-in fonts of the same size back up a font from disk.
        if (main_ok and set.fonts.items.len > 0) try set.addBuiltin(a, set.fonts.items[0].height);
        if (main_ok and set.fonts.items.len == 0) try set.addBuiltin(a, 16);

        self.fonts.deinit(a);
        self.fonts = set;
        self.renderer = render.Renderer.initMixed(self.fonts.ptrs.items, self.fonts.faces.items, self.settings.scale);

        const cols = self.out.width() / self.renderer.cell_w;
        const rows = self.out.height() / self.renderer.cell_h;
        self.cols = @intCast(@max(2, @min(cols, 1000)));
        self.rows = @intCast(@max(1, @min(rows, 1000)));
        self.origin_x = (self.out.width() - @as(u32, self.cols) * self.renderer.cell_w) / 2;
        self.origin_y = (self.out.height() - @as(u32, self.rows) * self.renderer.cell_h) / 2;
        log.info("layout: {s} font, cell {d}x{d}, {d} columns x {d} rows, margin {d},{d}", .{
            if (self.fonts.faces.items.len > 0) "TrueType" else "PSF", self.renderer.cell_w, self.renderer.cell_h,
            self.cols,                                                  self.rows,                                self.origin_x,
            self.origin_y,
        });
    }

    /// Input devices, the keymap and frame buffers: what only the visible VT
    /// holds.
    fn acquire(self: *Console) void {
        // The keyboard first. The kernel's own is off, so until ours is read
        // nobody can switch away from this VT.
        self.input.open();
        self.have_input = true;
        if (kbd.Keymap.load(self.allocator, self.vtdev.fd)) |km| {
            self.keymap.deinit();
            self.keymap = km;
            self.decoder = kbd.Decoder.init(&self.keymap);
        } else |e| log.warn("acquire: cannot read the keymap ({s}); keeping the previous one", .{@errorName(e)});
        log.debug("acquire: {d} input device(s)", .{self.input.devices.items.len});
        self.display_failures = 0;
        self.takeDisplay();
    }

    fn takeDisplay(self: *Console) void {
        self.display_retry_at = null;
        const d = &(self.dev orelse return);
        log.debug("acquire: taking the display", .{});
        d.setMaster();
        // Outputs are probed again on every acquire (SPEC.md 5.11).
        d.want = self.settings.mode;
        d.setDisplay(self.settings.display);
        if (d.probe(self.allocator)) |o| {
            const resized = o.width() != self.out.width() or o.height() != self.out.height();
            log.info("acquire: {d}x{d}@{d}{s}", .{ o.width(), o.height(), o.mode.vrefresh, if (resized) " (changed)" else "" });
            self.out = o;
            if (resized or self.layout_stale) {
                self.buildLayout() catch {};
                self.resizeTerminal();
                self.layout_stale = false;
            }
        } else |e| log.warn("acquire: probing the outputs failed ({s}); keeping the old mode", .{@errorName(e)});

        for (0..2) |i| {
            self.bufs[i] = d.createBuffer(self.out.width(), self.out.height()) catch |e| {
                log.err("acquire: cannot create frame buffer {d} ({s})", .{ i, @errorName(e) });
                return self.displayFailed();
            };
        }
        d.setMode(&self.out, &self.bufs[0].?) catch |e| {
            log.err("acquire: cannot set the mode ({s})", .{@errorName(e)});
            return self.displayFailed();
        };
        self.back = 1;
        self.flip_pending = false;
        self.have_display = true;
        self.display_failures = 0;
        for (&self.damage) |*dm| dm.full = true;
        log.debug("acquire: done", .{});
        self.draw(0);
    }

    /// Never keeps a blank VT for good: tries again shortly, with the keyboard
    /// still working, and in the end gives the VT to the fallback getty.
    fn displayFailed(self: *Console) void {
        self.freeBuffers();
        if (self.display_failures >= display_retry_ms.len) {
            log.warn("acquire: giving up on the display", .{});
            self.use_fallback = true;
            self.quit = true;
            return;
        }
        const wait = display_retry_ms[self.display_failures];
        self.display_failures += 1;
        self.display_retry_at = nowMs() + wait;
        log.warn("acquire: trying the display again in {d} ms", .{wait});
    }

    fn freeBuffers(self: *Console) void {
        self.have_display = false;
        self.flip_pending = false;
        if (self.dev) |*d| {
            for (&self.bufs) |*b| if (b.*) |*buf| {
                d.destroyBuffer(buf);
                b.* = null;
            };
        }
        for (&self.damage) |*dm| dm.rows.clearRetainingCapacity();
    }

    fn releaseDisplayResources(self: *Console) void {
        self.freeBuffers();
        self.display_retry_at = null;
        self.have_input = false;
        self.input.closeAll();
        self.decoder.reset();
        self.selecting = false;
    }

    /// The kernel asks to switch away: let go of everything, then say yes. The
    /// acknowledgement is sent no matter what, or the user cannot leave.
    fn release(self: *Console) void {
        log.debug("release: another VT is being shown", .{});
        if (self.dev) |*d| {
            d.dropMaster();
        }
        self.releaseDisplayResources();
        self.vtdev.ackRelease();
    }

    fn onAcquire(self: *Console) void {
        self.vtdev.ackAcquire();
        self.acquire();
    }

    // ---- terminal --------------------------------------------------------------------

    fn setupTerminal(self: *Console) !void {
        self.term = try self.newTerminal();
        self.attachStream();
    }

    fn newTerminal(self: *Console) !vt.Terminal {
        const a = self.allocator;
        var colors = try termcore.glue.terminalColors(a, self.scheme);
        // The terminal frees the palette once it has taken it.
        errdefer colors.palette.deinit(a);
        return vt.Terminal.init(self.tiny_io.io(), a, .{
            .cols = self.cols,
            .rows = self.rows,
            .max_scrollback_lines = self.settings.scrollback_lines,
            .colors = colors,
        });
    }

    /// The parser for `self.term`, answering through this console.
    fn attachStream(self: *Console) void {
        self.stream = self.term.vtStream();
        var e = vt.TerminalStream.Handler.Effects.readonly;
        e.write_pty = onWritePty;
        e.render_hold = onRenderHold;
        e.clipboard_write = onClipboardWrite;
        e.device_attributes = onDeviceAttributes;
        e.size = onSizeReport;
        e.xtversion = onXtversion;
        self.stream.handler.effects = e;
    }

    fn deinitTerminal(self: *Console) void {
        self.state.deinit(self.allocator);
        self.state = .empty;
        self.stream.deinit();
        self.term.deinit(self.allocator);
    }

    /// Nothing of a session may reach the next one: its screens, scrollback,
    /// modes, colours and what it copied all go. A new terminal does that;
    /// escape sequences cannot.
    fn newSession(self: *Console) !void {
        const fresh = try self.newTerminal();
        self.deinitTerminal();
        self.term = fresh;
        self.attachStream();
        self.setPrimary("");
        self.hold_until = null;
        self.selecting = false;
        self.anchor = null;
        self.pointer_visible = false;
        self.last_cursor = null;
        self.markAll();
    }

    /// Replaces the paste buffer. It can hold secrets, so what it held is wiped.
    fn setPrimary(self: *Console, text: []const u8) void {
        std.crypto.secureZero(u8, self.primary.allocatedSlice());
        self.primary.clearAndFree(self.allocator);
        self.primary.appendSlice(self.allocator, text) catch {};
    }

    fn fromHandler(handler: *vt.TerminalStream.Handler) *Console {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    fn onWritePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
        fromHandler(handler).send(&.{data});
    }

    /// Sends `parts` to the program as one message: all of it arrives, in
    /// order, or none of it is sent and the log says so.
    fn send(self: *Console, parts: []const []const u8) void {
        if (!self.login_running) return;
        self.outbox.queue(self.allocator, parts) catch |e| {
            log.warn("input not sent: {s}", .{@errorName(e)});
            return;
        };
        self.flushInput();
    }

    fn flushInput(self: *Console) void {
        // A failed write means the terminal has hung up; keeping the input
        // for whoever opens it next would be wrong.
        self.outbox.flush(self.allocator, &self.pty) catch self.outbox.clear(self.allocator);
    }

    fn onRenderHold(handler: *vt.TerminalStream.Handler, hold: bool) void {
        fromHandler(handler).hold_until = if (hold) nowMs() + render_hold_ms else null;
    }

    /// Ends a hold that has run too long, and says whether it did.
    fn expireRenderHold(self: *Console, now: i64) bool {
        const deadline = self.hold_until orelse return false;
        if (now < deadline) return false;
        self.hold_until = null;
        self.term.modes.set(.synchronized_output, false);
        self.markAll();
        return true;
    }

    fn onClipboardWrite(handler: *vt.TerminalStream.Handler, write: vt.clipboard.Write) void {
        const self = fromHandler(handler);
        for (write.contents) |c| {
            if (!std.mem.eql(u8, c.mime, "text/plain")) continue;
            self.setPrimary(c.data);
            return;
        }
    }

    fn onDeviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }

    fn onSizeReport(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{ .rows = self.rows, .columns = self.cols, .cell_width = @intCast(self.renderer.cell_w), .cell_height = @intCast(self.renderer.cell_h) };
    }

    fn onXtversion(_: *vt.TerminalStream.Handler) []const u8 {
        return "dkconsole 0.1";
    }

    fn ptySize(self: *const Console) termcore.pty.Size {
        return .{ .cols = self.cols, .rows = self.rows, .cell_w = @intCast(self.renderer.cell_w), .cell_h = @intCast(self.renderer.cell_h) };
    }

    fn resizeTerminal(self: *Console) void {
        self.stream.handler.resize(.{
            .cols = self.cols,
            .rows = self.rows,
            .cell_size_px = .{ .width = self.renderer.cell_w, .height = self.renderer.cell_h },
        }) catch |e| log.warn("resize failed: {s}", .{@errorName(e)});
        if (self.login_running) self.pty.resize(self.ptySize());
    }

    // ---- login -------------------------------------------------------------------------

    fn startLogin(self: *Console) void {
        const a = self.allocator;
        self.login_retry_at = null;
        self.printIssue();
        const configured = a.dupeSentinel(u8, self.settings.login_program, 0) catch return self.loginFailed();
        defer a.free(configured);
        if (configured.len > 0 and !sys.exists(configured)) log.warn("login-program {s} does not exist; looking for a login in the usual places", .{configured});
        const path: [:0]const u8 = if (configured.len > 0 and sys.exists(configured)) configured else for (login_paths) |p| {
            if (sys.exists(p)) break p;
        } else {
            log.warn("no login program found (tried {s}, ...)", .{login_paths[0]});
            self.stream.nextSlice("dkconsole: no login program found\r\n");
            return self.loginFailed();
        };
        var failure: c_int = 0;
        self.pty = Pty.spawn(a, .{
            .failure_errno = &failure,
            .path = path,
            .argv = &.{"login"},
            .env = &.{ "TERM=xterm-256color", "COLORTERM=truecolor" },
            .size = self.ptySize(),
        }) catch |e| {
            log.warn("cannot start {s}: {s} (errno {d})", .{ path, @errorName(e), failure });
            self.stream.nextSlice("dkconsole: cannot start login\r\n");
            return self.loginFailed();
        };
        self.login_started_at = nowMs();
        self.login_running = true;
        log.info("login started: {s}, pid {d}", .{ path, self.pty.pid });
    }

    /// Tries again shortly, or gives the VT to the fallback getty: a console
    /// that cannot offer a login must not keep the VT.
    fn loginFailed(self: *Console) void {
        self.login_failures += 1;
        if (self.login_failures >= max_login_failures) {
            log.warn("login failed {d} times in a row; giving up", .{self.login_failures});
            self.use_fallback = true;
            self.quit = true;
            return;
        }
        self.login_retry_at = nowMs() + login_retry_ms;
    }

    fn printIssue(self: *Console) void {
        const a = self.allocator;
        const path = if (self.settings.issue_file.len > 0) self.settings.issue_file else return;
        const text = sys.readFile(a, path, 64 << 10) catch |e| {
            if (e != error.NotFound) log.warn("{s}: not shown ({s}; the limit is 64 KiB)", .{ path, @errorName(e) });
            return;
        };
        defer a.free(text);
        var uts: issue.Uts = .{};
        var line: [16]u8 = undefined;
        const tty = std.fmt.bufPrint(&line, "tty{d}", .{self.vt_num}) catch "tty";
        var sysinfo = uts.system(tty);
        var clock: issue.Clock = .{};
        clock.now();
        sysinfo.date = clock.date;
        sysinfo.time = clock.time;
        const os_release = sys.readFile(a, "/etc/os-release", 16 << 10) catch a.alloc(u8, 0) catch return;
        defer a.free(os_release);
        sysinfo.os_release = os_release;
        const utmp = sys.readFile(a, "/var/run/utmp", 1 << 20) catch a.alloc(u8, 0) catch return;
        defer a.free(utmp);
        sysinfo.users = issue.countUsers(utmp);
        sysinfo.addr_fn = issue.systemAddress;
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        issue.expand(&aw.writer, text, sysinfo) catch return;
        self.stream.nextSlice(aw.written());
    }

    /// `login` ended: discard the session and start it again. It never runs a
    /// shell itself.
    fn loginExited(self: *Console) void {
        log.info("login ended; starting it again", .{});
        const quick = self.login_started_at != 0 and nowMs() - self.login_started_at < quick_login_ms;
        self.pty.deinit();
        self.pty_resume_at = null;
        self.outbox.clear(self.allocator);
        self.login_running = false;
        self.newSession() catch |e| {
            // The old session must not be shown to anyone else. Leaving lets
            // the init system start a clean console.
            log.err("cannot make a new terminal ({s}); restarting", .{@errorName(e)});
            self.quit = true;
            return;
        };
        if (quick) return self.loginFailed();
        self.login_failures = 0;
        self.startLogin();
    }

    // ---- the loop ---------------------------------------------------------------------

    fn loop(self: *Console) void {
        var fds: [96]evdev.PollFd = undefined;
        var events: std.ArrayList(evdev.Event) = .empty;
        defer events.deinit(self.allocator);

        while (!self.quit) {
            var n: usize = 0;
            const sig_i = n;
            fds[n] = .{ .fd = self.sig_fd, .events = evdev.POLLIN, .revents = 0 };
            n += 1;
            const pty_i = n;
            fds[n] = self.ptyPollFd(nowMs());
            n += 1;
            const conf_i = n;
            fds[n] = .{ .fd = self.conf_watch, .events = evdev.POLLIN, .revents = 0 };
            n += 1;
            const drm_i = n;
            fds[n] = .{ .fd = if (self.have_display and self.flip_pending) self.dev.?.fd else -1, .events = evdev.POLLIN, .revents = 0 };
            n += 1;
            const input_i = n;
            if (self.have_input) n += self.input.pollFds(fds[n..]);

            const r = poll(&fds, n, self.timeoutMs());
            if (r < 0) {
                if (sys.errno() == sys.EINTR) continue;
                log.err("poll failed (errno {d}); stopping", .{sys.errno()});
                break;
            }
            const now = nowSeconds();
            if (!self.healthy_done and now >= self.healthy_at) {
                fallback.writeCounter(self.vt_num, 0);
                self.healthy_done = true;
            }

            var dirty = false;
            if (fds[sig_i].revents != 0) self.handleSignals(&dirty);
            if (self.quit) break;
            if (fds[conf_i].revents != 0) self.reloadConfig(&dirty);
            if (fds[pty_i].revents & evdev.POLLOUT != 0 and self.login_running) self.flushInput();
            if (fds[pty_i].revents & ~@as(c_short, evdev.POLLOUT) != 0) self.readPty(&dirty);
            if (fds[drm_i].revents != 0) {
                if (self.dev.?.readEvents() > 0) {
                    self.flip_pending = false;
                    self.back ^= 1;
                    dirty = true;
                }
            }
            if (self.have_input) {
                events.clearRetainingCapacity();
                for (fds[input_i..n]) |p| {
                    if (p.revents != 0) self.input.service(p.fd, &events);
                }
                for (events.items) |ev| {
                    if (self.have_display) self.handleInput(ev, &dirty) else self.handleBlindInput(ev);
                }
            }
            if (self.login_retry_at) |at| if (nowMs() >= at) {
                self.startLogin();
                dirty = true;
            };
            if (self.display_retry_at) |at| if (nowMs() >= at) {
                self.takeDisplay();
                dirty = true;
            };
            if (self.quit) break;
            if (self.expireRenderHold(nowMs())) dirty = true;
            if (self.cursor_blink_due(now)) dirty = true;
            if (dirty) self.draw(now);
        }
    }

    fn ptyPollFd(self: *Console, now: i64) evdev.PollFd {
        if (self.pty_resume_at) |at| if (now >= at) {
            self.pty_resume_at = null;
        };
        return .{
            .fd = if (self.login_running and self.pty_resume_at == null) self.pty.fd() else -1,
            .events = if (self.outbox.pending()) evdev.POLLIN | evdev.POLLOUT else evdev.POLLIN,
            .revents = 0,
        };
    }

    fn timeoutMs(self: *const Console) c_int {
        var ms: i64 = -1;
        const now = nowSeconds();
        if (!self.healthy_done) ms = @max(0, self.healthy_at - now) * 1000;
        if (self.have_display and self.settings.cursor_blink) {
            ms = if (ms < 0) 500 else @min(ms, 500);
        }
        for ([_]?i64{ self.display_retry_at, self.login_retry_at, self.hold_until, self.pty_resume_at }) |deadline| {
            const left = @max(0, (deadline orelse continue) - nowMs());
            ms = if (ms < 0) left else @min(ms, left);
        }
        return @intCast(ms);
    }

    fn cursor_blink_due(self: *Console, now: i64) bool {
        _ = now;
        if (!self.have_display or !self.settings.cursor_blink) return false;
        // Toggled once per poll timeout; the timer runs only on the visible VT.
        var ts: Timespec = undefined;
        _ = clock_gettime(1, &ts);
        const ms = ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
        if (ms < self.next_blink) return false;
        self.next_blink = ms + 500;
        self.cursor_on = !self.cursor_on;
        return true;
    }

    fn handleSignals(self: *Console, dirty: *bool) void {
        var buf: [32]u8 = undefined;
        for (vtmod.drainSignals(self.sig_fd, &buf)) |s| {
            switch (s) {
                vtmod.SIGUSR1 => self.release(),
                vtmod.SIGUSR2 => {
                    self.onAcquire();
                    dirty.* = true;
                },
                vtmod.SIGCHLD => if (self.login_running) {
                    if (self.pty.poll() != null) {
                        self.loginExited();
                        dirty.* = true;
                    }
                },
                else => self.quit = true, // TERM, INT, HUP
            }
        }
    }

    fn reloadConfig(self: *Console, dirty: *bool) void {
        var buf: [512]u8 align(4) = undefined;
        while (sys.read(self.conf_watch, &buf, buf.len) > 0) {}
        // The strings of the old settings live in documents that loadSettings
        // frees, so keep copies of the ones compared below.
        const a = self.allocator;
        const old_font = a.dupe(u8, self.settings.font) catch return;
        defer a.free(old_font);
        const old_fallbacks = a.dupe(u8, self.settings.fallback_fonts) catch return;
        defer a.free(old_fallbacks);
        const old_size = self.settings.font_size;
        const old_scale = self.settings.scale;
        const old_mode = self.settings.mode;
        const old_display = a.dupe(u8, self.settings.display) catch return;
        defer a.free(old_display);
        log.info("{s} changed; reading it again", .{configtool.etcPath()});
        self.loadSettings();
        // Fonts and colours change on the next frame; `fallback` is read at start-up.
        const font_changed = !std.mem.eql(u8, old_font, self.settings.font) or
            !std.mem.eql(u8, old_fallbacks, self.settings.fallback_fonts) or
            old_size != self.settings.font_size or old_scale != self.settings.scale;
        if (font_changed) {
            if (self.have_display) {
                self.buildLayout() catch |e| {
                    log.err("cannot rebuild the layout after a font change: {s}", .{@errorName(e)});
                    return;
                };
                self.resizeTerminal();
            } else self.layout_stale = true;
        }
        // A different mode or connector is applied by taking the display again.
        if (self.have_display and (!std.meta.eql(old_mode, self.settings.mode) or !std.mem.eql(u8, old_display, self.settings.display))) {
            log.info("display settings changed; switching the display", .{});
            self.releaseDisplayResources();
            self.acquire();
        }
        self.term.colors.background = .init(termcore.glue.rgb(self.scheme.background));
        self.term.colors.foreground = .init(termcore.glue.rgb(self.scheme.foreground));
        self.term.colors.palette.changeDefault(self.allocator, termcore.glue.palette(self.scheme)) catch {};
        for (&self.damage) |*dm| dm.full = true;
        dirty.* = true;
    }

    fn readPty(self: *Console, dirty: *bool) void {
        if (!self.login_running) return;
        var buf: [16384]u8 = undefined;
        var rounds: usize = 0;
        // Bounded, so a flood of output cannot starve the keyboard.
        while (rounds < 16) : (rounds += 1) {
            const n = self.pty.readSome(&buf) catch {
                // Nothing has the terminal open. Usually login has ended;
                // if it still runs, do not spin on the descriptor.
                if (self.pty.poll() != null) self.loginExited() else self.pty_resume_at = nowMs() + hangup_wait_ms;
                dirty.* = true;
                return;
            };
            if (n == 0) break;
            self.stream.nextSlice(buf[0..n]);
            dirty.* = true;
        }
    }

    // ---- drawing ---------------------------------------------------------------------

    fn markRow(self: *Console, y: usize) void {
        for (&self.damage) |*dm| {
            if (dm.full) continue;
            if (dm.rows.items.len <= y) dm.rows.resize(self.allocator, y + 1) catch {
                dm.full = true;
                continue;
            };
            dm.rows.items[y] = true;
        }
    }

    fn markAll(self: *Console) void {
        for (&self.damage) |*dm| dm.full = true;
    }

    fn draw(self: *Console, now: i64) void {
        _ = now;
        if (!self.have_display or self.hold_until != null) return;
        self.state.update(self.allocator, &self.term) catch return;

        // What the renderer says changed, plus the cursor's old and new rows.
        if (self.state.dirty != .false) {
            self.markAll();
        } else {
            const row_data = self.state.row_data.slice();
            for (row_data.items(.dirty), 0..) |d, y| if (d) self.markRow(y);
        }
        const cursor = self.cursorToDraw();
        if (self.last_cursor) |lc| self.markRow(lc.y);
        if (cursor) |c| self.markRow(c.y);
        self.last_cursor = if (cursor) |c| .{ .x = c.x, .y = c.y } else null;
        self.markPointerRows();
        self.state.clean();

        if (self.flip_pending) return; // keep the damage; the flip event brings us back
        const dm = &self.damage[self.back];
        const any = dm.full or std.mem.indexOfScalar(bool, dm.rows.items, true) != null;
        if (!any) return;
        const buf = &self.bufs[self.back].?;

        if (dm.full) {
            self.renderer.drawMargins(buf, self.origin_y, self.rows, render.pack(self.state.colors.background));
            for (0..self.state.rows) |y| self.renderer.drawRow(buf, self.origin_x, self.origin_y, &self.state, y, cursor);
        } else {
            for (dm.rows.items, 0..) |d, y| {
                if (d and y < self.state.rows) self.renderer.drawRow(buf, self.origin_x, self.origin_y, &self.state, y, cursor);
            }
        }
        dm.full = false;
        @memset(dm.rows.items, false);
        if (self.pointer_visible) render.drawPointer(buf, @intCast(@max(0, self.pointer_x)), @intCast(@max(0, self.pointer_y)));

        if (self.dev.?.flip(&self.out, buf)) {
            self.flip_pending = true;
        } else {
            // The flip failed (the display went away?): retry on the next change.
            self.markAll();
        }
    }

    fn cursorToDraw(self: *const Console) ?render.Cursor {
        const c = self.state.cursor;
        if (!c.visible) return null;
        const pos = c.viewport orelse return null;
        if (c.blinking and self.settings.cursor_blink and !self.cursor_on) return null;
        return .{
            .x = pos.x,
            .y = pos.y,
            .style = switch (c.visual_style) {
                .block => .block,
                .block_hollow => .hollow,
                .bar => .bar,
                .underline => .underline,
            },
            .color = self.state.colors.cursor orelse self.state.colors.foreground,
        };
    }

    fn markPointerRows(self: *Console) void {
        if (self.pointer_shown_rows) |r| {
            var y = r[0];
            while (y <= r[1]) : (y += 1) self.markRow(y);
        }
        if (!self.pointer_visible) {
            self.pointer_shown_rows = null;
            return;
        }
        const cell_h = self.renderer.cell_h;
        const top = @as(u32, @intCast(@max(0, self.pointer_y)));
        const first = (top -| self.origin_y) / cell_h;
        const last = @min(@as(u32, self.rows) - 1, (top + render.pointer_h -| self.origin_y) / cell_h);
        self.pointer_shown_rows = .{ @min(first, last), last };
        var y = first;
        while (y <= last) : (y += 1) self.markRow(y);
    }

    // ---- input ---------------------------------------------------------------------

    fn handleInput(self: *Console, ev: evdev.Event, dirty: *bool) void {
        switch (ev) {
            .key => |k| self.handleKey(k.code, k.value, dirty),
            .motion => |m| {
                self.pointer_visible = true;
                self.pointer_x = std.math.clamp(self.pointer_x + m.dx, 0, @as(i32, @intCast(self.out.width())) - 1);
                self.pointer_y = std.math.clamp(self.pointer_y + m.dy, 0, @as(i32, @intCast(self.out.height())) - 1);
                self.pointerMoved(dirty);
            },
            .position => |p| {
                self.pointer_visible = true;
                self.pointer_x = @intCast(@as(u32, p.x) * (self.out.width() - 1) / 65535);
                self.pointer_y = @intCast(@as(u32, p.y) * (self.out.height() - 1) / 65535);
                self.pointerMoved(dirty);
            },
            .button => |b| self.handleButton(b.code, b.pressed, dirty),
            .wheel => |w| {
                if (self.term.flags.mouse_event != .none) {
                    var i: i32 = 0;
                    while (i < @abs(w)) : (i += 1) self.sendMouse(.press, if (w > 0) .four else .five);
                } else {
                    self.term.scrollViewport(.{ .delta = -@as(isize, w) * 3 });
                    dirty.* = true;
                }
            },
        }
    }

    /// With nothing on the screen only switching away works: nobody should
    /// type at a prompt they cannot see.
    fn handleBlindInput(self: *Console, ev: evdev.Event) void {
        switch (ev) {
            .key => |k| {
                const decoded = self.decoder.feed(k.code, k.value);
                if (kbd.vtSwitch(&decoded)) |n| self.vtdev.activate(n);
            },
            else => {},
        }
    }

    fn handleKey(self: *Console, code: u16, value: i32, dirty: *bool) void {
        const ev = self.decoder.feed(code, value);
        // The pointer hides again on the next key press.
        if (ev.action == .press and self.pointer_visible) {
            self.pointer_visible = false;
            dirty.* = true;
        }
        if (kbd.vtSwitch(&ev)) |n| {
            self.vtdev.activate(n);
            return;
        }
        if (ev.action != .release and ev.shift and !ev.ctrl and !ev.alt) {
            switch (code) {
                104 => { // Shift+PageUp
                    self.term.scrollViewport(.{ .delta = -@as(isize, self.rows) + 1 });
                    dirty.* = true;
                    return;
                },
                109 => { // Shift+PageDown
                    self.term.scrollViewport(.{ .delta = @as(isize, self.rows) - 1 });
                    dirty.* = true;
                    return;
                },
                110 => { // Shift+Insert
                    if (ev.action == .press) self.pasteText(self.primary.items);
                    return;
                },
                else => {},
            }
        }
        if (!self.login_running) return;
        if (ev.action != .release) self.term.scrollViewport(.bottom);

        var event: vt.input.KeyEvent = .{
            .action = switch (ev.action) {
                .press => .press,
                .repeat => .repeat,
                .release => .release,
            },
            .key = termcore.keymap.fromEvdev(code),
            .mods = .{ .shift = ev.shift, .ctrl = ev.ctrl, .alt = ev.alt, .super = ev.super, .caps_lock = ev.caps_lock, .num_lock = ev.num_lock },
            .utf8 = if (ev.action == .release) "" else ev.textSlice(),
            .unshifted_codepoint = ev.unshifted,
        };
        if (event.utf8.len > 0 and ev.shift) event.consumed_mods = .{ .shift = true };
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const opts = vt.input.KeyEncodeOptions.fromTerminal(&self.term);
        vt.input.encodeKey(&w, event, opts) catch return;
        const out = w.buffered();
        if (out.len > 0) self.send(&.{out});
        dirty.* = true;
    }

    fn pasteText(self: *Console, text: []const u8) void {
        if (text.len == 0 or !self.login_running) return;
        const copy = self.allocator.dupe(u8, text) catch return;
        defer self.allocator.free(copy);
        const opts = vt.input.PasteOptions.fromTerminal(&self.term);
        const parts = vt.input.encodePaste(copy, opts);
        self.send(&parts);
        self.term.scrollViewport(.bottom);
    }

    fn cellAt(self: *const Console) struct { col: u16, row: u16 } {
        const x = @as(u32, @intCast(@max(0, self.pointer_x)));
        const y = @as(u32, @intCast(@max(0, self.pointer_y)));
        const col = @min(@as(u32, self.cols) - 1, (x -| self.origin_x) / self.renderer.cell_w);
        const row = @min(@as(u32, self.rows) - 1, (y -| self.origin_y) / self.renderer.cell_h);
        return .{ .col = @intCast(col), .row = @intCast(row) };
    }

    fn sendMouse(self: *Console, action: vt.input.MouseAction, button: ?vt.input.MouseButton) void {
        if (!self.login_running) return;
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const MouseSize = @FieldType(vt.input.MouseEncodeOptions, "size");
        const size: MouseSize = .{
            .screen = .{ .width = self.out.width(), .height = self.out.height() },
            .cell = .{ .width = self.renderer.cell_w, .height = self.renderer.cell_h },
            .padding = .{ .top = self.origin_y, .bottom = self.origin_y, .right = self.origin_x, .left = self.origin_x },
        };
        var opts = vt.input.MouseEncodeOptions.fromTerminal(&self.term, size);
        opts.any_button_pressed = self.selecting;
        vt.input.encodeMouse(&w, .{
            .action = action,
            .button = button,
            .mods = .{ .shift = self.decoder.held[0] > 0, .ctrl = self.decoder.held[2] > 0, .alt = self.decoder.held[3] > 0 },
            .pos = .{ .x = @floatFromInt(self.pointer_x), .y = @floatFromInt(self.pointer_y) },
        }, opts) catch return;
        self.send(&.{w.buffered()});
    }

    fn pointerMoved(self: *Console, dirty: *bool) void {
        dirty.* = true;
        const shift = self.decoder.held[0] > 0;
        if (self.term.flags.mouse_event != .none and !shift) {
            if (self.term.flags.mouse_event == .any or (self.term.flags.mouse_event == .button and self.selecting))
                self.sendMouse(.motion, null);
            return;
        }
        if (!self.selecting) return;
        const cell = self.cellAt();
        const screen = self.term.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
        const anchor = self.anchor orelse return;
        screen.select(vt.Selection.init(anchor, pin, self.decoder.held[3] > 0)) catch return;
    }

    fn handleButton(self: *Console, code: u16, pressed: bool, dirty: *bool) void {
        dirty.* = true;
        const button: vt.input.MouseButton = switch (code) {
            evdev.BTN_LEFT => .left,
            evdev.BTN_RIGHT => .right,
            evdev.BTN_MIDDLE => .middle,
            else => return,
        };
        const shift = self.decoder.held[0] > 0;
        if (self.term.flags.mouse_event != .none and !shift) {
            self.selecting = pressed;
            self.sendMouse(if (pressed) .press else .release, button);
            return;
        }
        if (button == .middle) {
            if (pressed) self.pasteText(self.primary.items);
            return;
        }
        if (button != .left) return;
        const screen = self.term.screens.active;
        if (pressed) {
            const cell = self.cellAt();
            const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
            self.selecting = true;
            self.anchor = pin;
            screen.clearSelection();
        } else {
            self.selecting = false;
            // Selecting copies, within this console (SPEC.md 5.11).
            const selection = screen.selection orelse return;
            const text = screen.selectionString(self.allocator, .{ .sel = selection }) catch return;
            defer self.allocator.free(text);
            self.setPrimary(text);
        }
    }
};

// ---- tests ------------------------------------------------------------------------

/// A console with a terminal and no kernel devices. Its "login" is /bin/true.
fn testConsole(a: std.mem.Allocator) !*Console {
    const c = try a.create(Console);
    errdefer a.destroy(c);
    c.* = .{ .allocator = a, .vt_num = 1 };
    c.settings = config.Settings.resolve(.{}, 1);
    c.settings.login_program = "/bin/true";
    c.settings.issue_file = "";
    // Otherwise the pending health check makes every poll timeout 0.
    c.healthy_done = true;
    c.scheme = termcore.schemes.scheme("campbell");
    c.renderer.cell_w = 8;
    c.renderer.cell_h = 16;
    try c.setupTerminal();
    return c;
}

fn destroyTestConsole(c: *Console) void {
    const a = c.allocator;
    c.pty.deinit();
    c.outbox.deinit(a);
    c.primary.deinit(a);
    c.fonts.deinit(a);
    if (c.docs_loaded) {
        c.etc_doc.deinit();
        c.defs_doc.deinit();
    }
    for (&c.damage) |*d| d.rows.deinit(a);
    c.deinitTerminal();
    a.destroy(c);
}

fn screenHas(c: *Console, needle: []const u8) !bool {
    const text = try c.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(text);
    return std.mem.indexOf(u8, text, needle) != null;
}

test "nothing of a session survives logout" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    const background = c.term.colors.background.get();
    const foreground = c.term.colors.foreground.get();

    // Output, a clipboard write, then the alternate screen with modes, black
    // on black, and a synchronized update left open.
    c.stream.nextSlice("TOPSECRET-FIRST-USER\r\n");
    c.stream.nextSlice("\x1b]52;c;aHVudGVyMi1jbGlwYm9hcmQ=\x07");
    try std.testing.expectEqualStrings("hunter2-clipboard", c.primary.items);
    c.stream.nextSlice("\x1b[?1049h\x1b[?2004h\x1b[?1000h\x1b]11;#000000\x07\x1b]10;#000000\x07\x1b[?2026h");
    try std.testing.expect(c.hold_until != null);
    c.selecting = true;
    c.pointer_visible = true;

    c.loginExited();

    try std.testing.expectEqual(@as(usize, 0), c.primary.items.len);
    try std.testing.expect(c.hold_until == null and !c.selecting and !c.pointer_visible);
    try std.testing.expect(!c.term.modes.get(.bracketed_paste));
    try std.testing.expectEqual(@as(@TypeOf(c.term.flags.mouse_event), .none), c.term.flags.mouse_event);
    try std.testing.expectEqual(background, c.term.colors.background.get());
    try std.testing.expectEqual(foreground, c.term.colors.foreground.get());
    try std.testing.expect(!try screenHas(c, "TOPSECRET"));
    c.stream.nextSlice("\x1b[?1049l");
    try std.testing.expect(!try screenHas(c, "TOPSECRET"));
}

test "a display that cannot be taken is retried, then given up" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    var waited: i64 = 0;
    for (display_retry_ms) |wait| {
        const before = nowMs();
        c.displayFailed();
        try std.testing.expect(!c.quit and !c.use_fallback);
        try std.testing.expect(c.display_retry_at.? >= before + wait);
        try std.testing.expect(c.timeoutMs() > wait - 50 and c.timeoutMs() <= wait);
        waited += wait;
    }
    try std.testing.expect(waited < 5000);
    c.displayFailed();
    try std.testing.expect(c.quit and c.use_fallback);
}

test "a login that cannot start is retried, then the fallback takes over" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    c.settings.login_program = "/etc/hostname"; // exists, cannot be run
    var tries: u32 = 1;
    c.startLogin();
    while (!c.quit) : (tries += 1) {
        try std.testing.expect(!c.login_running);
        try std.testing.expect(c.login_retry_at != null);
        try std.testing.expect(c.timeoutMs() > login_retry_ms - 500 and c.timeoutMs() <= login_retry_ms);
        c.startLogin();
    }
    try std.testing.expect(c.use_fallback);
    try std.testing.expectEqual(@as(u32, max_login_failures), tries);
    try std.testing.expect(try screenHas(c, "cannot start login"));
}

test "a login that keeps ending at once leads to the fallback" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    c.startLogin();
    var exits: u32 = 0;
    while (!c.quit and exits < 20) : (exits += 1) {
        if (!c.login_running) c.startLogin();
        c.loginExited();
    }
    try std.testing.expect(c.use_fallback);
    try std.testing.expectEqual(@as(u32, max_login_failures), exits);
}

test "a login that lasted clears the failure count" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    c.login_failures = max_login_failures - 1;
    c.login_started_at = nowMs() - quick_login_ms - 1;
    c.loginExited();
    try std.testing.expect(!c.quit);
    try std.testing.expectEqual(@as(u32, 0), c.login_failures);
    try std.testing.expect(c.login_running);
}

test "a render hold that is never released runs out" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    const before = nowMs();
    c.stream.nextSlice("\x1b[?2026h");
    const deadline = c.hold_until.?;
    try std.testing.expect(deadline >= before + render_hold_ms);
    try std.testing.expect(c.timeoutMs() > render_hold_ms - 500 and c.timeoutMs() <= render_hold_ms);
    try std.testing.expect(!c.expireRenderHold(deadline - 1));
    try std.testing.expect(c.expireRenderHold(deadline));
    try std.testing.expect(c.hold_until == null);
    try std.testing.expect(!c.term.modes.get(.synchronized_output));
    // Released in time, there is nothing to expire.
    c.stream.nextSlice("\x1b[?2026h\x1b[?2026l");
    try std.testing.expect(c.hold_until == null);
}

test "a hung-up terminal with a running program does not spin the loop" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    c.pty = try Pty.spawn(std.testing.allocator, .{
        .path = "/bin/sh",
        .argv = &.{ "sh", "-c", "exec <&- >&- 2>&-; sleep 0.5; echo back >/dev/tty; sleep 5" },
        .env = &.{"PATH=/usr/bin:/bin"},
        .size = .{ .cols = 80, .rows = 24 },
    });
    c.login_running = true;

    // The loop's own calls, for a second.
    var wakes: u32 = 0;
    var dirty = false;
    const end = nowMs() + 1000;
    while (nowMs() < end) {
        var fds = [1]evdev.PollFd{c.ptyPollFd(nowMs())};
        const wait = c.timeoutMs();
        _ = poll(&fds, 1, if (wait < 0 or wait > 100) 100 else wait);
        if (fds[0].revents != 0) c.readPty(&dirty);
        wakes += 1;
    }
    try std.testing.expect(wakes < 100);
    try std.testing.expect(c.login_running);
    // What the program wrote after reopening the terminal still arrived.
    try std.testing.expect(try screenHas(c, "back"));
}

/// A screen of `w` by `h` pixels, as far as laying out text goes.
fn setTestOutput(c: *Console, w: u16, h: u16) void {
    c.out.mode = std.mem.zeroes(drm.ModeInfo);
    c.out.mode.hdisplay = w;
    c.out.mode.vdisplay = h;
    c.out.mm_height = 0;
}

// The testing allocator reports leaks and double frees: what the console does
// again and again over its life must free what it replaces.
test "reloads, relayouts, selections and logouts free what they replace" {
    const c = try testConsole(std.testing.allocator);
    defer destroyTestConsole(c);
    setTestOutput(c, 1920, 1080);
    const dejavu = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
    const fonts = [_][]const u8{ "", "terminus-32", dejavu, "/etc/hostname", "/nonexistent" };
    var dirty = false;
    for (0..3) |_| {
        for (fonts) |font| {
            c.settings.font = font;
            c.settings.fallback_fonts = if (font.len == 0) dejavu else "/etc/hostname";
            try c.buildLayout();
            c.resizeTerminal();
            c.stream.nextSlice("some text to draw and select\r\n");
            try c.state.update(c.allocator, &c.term);
            for (c.renderer.faces) |face| _ = face.coverage('A', false, false, c.renderer.cell_w);
        }
        // Reading the settings again, as after a change to the file.
        c.loadSettings();
        c.reloadConfig(&dirty);
        c.settings.login_program = "/bin/true";
        c.settings.issue_file = "/etc/hostname";
        c.pointer_y = 0;
        c.pointer_x = 0;
        c.handleButton(evdev.BTN_LEFT, true, &dirty);
        c.pointer_x = 200;
        c.pointerMoved(&dirty);
        c.handleButton(evdev.BTN_LEFT, false, &dirty);
        for (&c.damage) |*d| d.full = false;
        c.markRow(40);
        c.markRow(3);
        c.loginExited();
    }
}
