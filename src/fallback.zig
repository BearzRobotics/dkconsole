//! Falling back to a plain text login (SPEC.md 5.11, *Fallback*). The console
//! must never be the reason a user cannot log in: when it cannot start, or has
//! been crashing, it `exec`s the fallback getty on the same VT.

const std = @import("std");
const sys = @import("sys.zig");
const config = @import("config.zig");
const Vt = @import("vt.zig").Vt;

extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const state_dir = "/run/dkconsole";
/// This many failures within the window latch the fallback for the boot.
pub const max_failures = 3;
pub const window_seconds = 60;

/// What one VT's console remembers between its starts (spec 16.2).
pub const State = struct {
    /// A start is in progress and has not ended cleanly. Left set by a crash
    /// or SIGKILL, which cannot record anything themselves.
    running: bool = false,
    /// Every later start goes to the fallback, until `recovery reset` or
    /// reboot.
    latched: bool = false,
    /// When the recent failures were noticed, in seconds since boot.
    failures: [max_failures]i64 = undefined,
    count: u32 = 0,

    /// Called at each start. Returns whether to go straight to the fallback;
    /// otherwise the start is now marked as in progress.
    pub fn start(self: *State, now: i64) bool {
        // The previous start never ended cleanly: that is one failure.
        if (self.running) self.fail(now);
        self.running = !self.latched;
        return self.latched;
    }

    /// An orderly stop is not a failure.
    pub fn stop(self: *State) void {
        self.running = false;
    }

    /// Records one failure and ends the start it happened in.
    pub fn fail(self: *State, now: i64) void {
        self.running = false;
        self.expire(now);
        if (self.count == max_failures) self.drop(1);
        self.failures[self.count] = now;
        self.count += 1;
        if (self.count == max_failures) self.latched = true;
    }

    /// Forgets failures that have left the window.
    pub fn expire(self: *State, now: i64) void {
        var old: u32 = 0;
        while (old < self.count and now - self.failures[old] >= window_seconds) old += 1;
        self.drop(old);
    }

    fn drop(self: *State, n: u32) void {
        std.mem.copyForwards(i64, self.failures[0 .. self.count - n], self.failures[n..self.count]);
        self.count -= n;
    }

    /// Reads the file's text. State left by another boot, `boot` being this
    /// one's identifier, counts for nothing.
    pub fn parse(text: []const u8, boot: []const u8) State {
        var state: State = .{};
        var same_boot = false;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            const name = words.next() orelse continue;
            if (std.mem.eql(u8, name, "boot")) {
                same_boot = std.mem.eql(u8, words.next() orelse "", boot);
            } else if (std.mem.eql(u8, name, "running")) {
                state.running = true;
            } else if (std.mem.eql(u8, name, "latched")) {
                state.latched = true;
            } else if (std.mem.eql(u8, name, "failure")) {
                const when = std.fmt.parseInt(i64, words.next() orelse "", 10) catch continue;
                if (state.count < max_failures) {
                    state.failures[state.count] = when;
                    state.count += 1;
                }
            }
        }
        return if (same_boot) state else .{};
    }

    pub fn write(self: State, w: *std.Io.Writer, boot: []const u8) !void {
        try w.print("boot {s}\n", .{boot});
        if (self.running) try w.writeAll("running\n");
        if (self.latched) try w.writeAll("latched\n");
        for (self.failures[0..self.count]) |when| try w.print("failure {d}\n", .{when});
    }
};

const Timespec = extern struct { sec: c_long, nsec: c_long };
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;

/// Seconds since boot, time asleep included.
pub fn bootSeconds() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(7, &ts); // CLOCK_BOOTTIME
    return ts.sec;
}

fn bootId(allocator: std.mem.Allocator, buf: []u8) []const u8 {
    const text = sys.readFile(allocator, "/proc/sys/kernel/random/boot_id", 64) catch return "unknown";
    defer allocator.free(text);
    const id = std.mem.trim(u8, text, " \n");
    const n = @min(id.len, buf.len);
    @memcpy(buf[0..n], id[0..n]);
    return buf[0..n];
}

pub fn statePath(buf: []u8, vt: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/tty{d}.state", .{ state_dir, vt }) catch "";
}

pub fn load(allocator: std.mem.Allocator, vt: u32) State {
    var pb: [64]u8 = undefined;
    const text = sys.readFile(allocator, statePath(&pb, vt), 1024) catch return .{};
    defer allocator.free(text);
    var ib: [64]u8 = undefined;
    return State.parse(text, bootId(allocator, &ib));
}

pub fn save(allocator: std.mem.Allocator, vt: u32, state: State) !void {
    var pb: [64]u8 = undefined;
    var ib: [64]u8 = undefined;
    var text: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);
    try state.write(&w, bootId(allocator, &ib));
    sys.makeDir(state_dir);
    try sys.writeFileAtomic(statePath(&pb, vt), w.buffered());
}

/// Replace this process with the fallback getty. Only returns if nothing could
/// be started; then it tries the plain `login`-less last resorts so the VT is
/// not left blank.
pub fn execFallback(allocator: std.mem.Allocator, template: []const u8, vt: *const Vt) void {
    vt.restoreText();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    config.expandFallback(&aw.writer, template, vt.num) catch return;
    tryExec(allocator, aw.written());
    // The configured command did not start: the usual getty places, in order.
    var b: [96]u8 = undefined;
    for ([_][]const u8{ "/sbin/agetty --noclear tty%N linux", "/sbin/getty 38400 tty%N", "/usr/sbin/agetty --noclear tty%N linux" }) |cmd| {
        var w: std.Io.Writer = .fixed(&b);
        config.expandFallback(&w, cmd, vt.num) catch continue;
        tryExec(allocator, w.buffered());
    }
}

fn tryExec(allocator: std.mem.Allocator, command: []const u8) void {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(allocator);
    var strings: std.ArrayList([:0]u8) = .empty;
    defer {
        for (strings.items) |s| allocator.free(s);
        strings.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |tok| {
        const z = allocator.dupeSentinel(u8, tok, 0) catch return;
        strings.append(allocator, z) catch {
            allocator.free(z);
            return;
        };
        argv.append(allocator, z.ptr) catch return;
    }
    if (argv.items.len == 0) return;
    argv.append(allocator, null) catch return;
    _ = execv(argv.items[0].?, @ptrCast(argv.items.ptr));
}

test "the third failure within a minute latches the fallback" {
    var s: State = .{};
    try std.testing.expect(!s.start(100));
    // Each later start finds the marker of the one that crashed.
    try std.testing.expect(!s.start(101));
    try std.testing.expect(!s.start(102));
    try std.testing.expect(s.start(103));
    try std.testing.expect(s.latched and !s.running);
    // A fallback getty that lasts does not clear it.
    try std.testing.expect(s.start(10_000));
}

test "orderly stops and restarts are not failures" {
    var s: State = .{};
    for (0..20) |i| {
        try std.testing.expect(!s.start(100 + @as(i64, @intCast(i))));
        s.stop();
    }
    try std.testing.expectEqual(@as(u32, 0), s.count);
}

test "failures leave the window after a minute" {
    var s: State = .{};
    s.fail(100);
    s.fail(130);
    s.fail(160); // the first is 60 s old
    try std.testing.expect(!s.latched);
    try std.testing.expectEqual(@as(u32, 2), s.count);
    s.fail(161);
    try std.testing.expect(s.latched);
}

test "the state round-trips and belongs to one boot" {
    var s: State = .{};
    s.fail(5);
    s.running = true;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.write(&w, "this-boot");
    const same = State.parse(w.buffered(), "this-boot");
    try std.testing.expect(same.running and !same.latched);
    try std.testing.expectEqual(@as(u32, 1), same.count);
    try std.testing.expectEqual(@as(i64, 5), same.failures[0]);
    const other = State.parse(w.buffered(), "another-boot");
    try std.testing.expect(!other.running and other.count == 0);
}
