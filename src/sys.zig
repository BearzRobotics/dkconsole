//! The few libc calls the console uses directly (SPEC.md 5.11). The console
//! talks to the kernel through file descriptors and ioctls; going through libc
//! (which Zig's standard library does too) keeps this file short and the same
//! for glibc and musl.

const std = @import("std");

pub extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub extern fn close(fd: c_int) c_int;
pub extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
pub extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
pub extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
pub extern fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
pub extern fn unlink(path: [*:0]const u8) c_int;
pub extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
pub extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub extern fn geteuid() c_uint;
pub extern fn access(path: [*:0]const u8, mode: c_int) c_int;
pub extern fn __errno_location() *c_int;

pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;
pub const O_CREAT = 0o100;
pub const O_TRUNC = 0o1000;
pub const O_NONBLOCK = 0o4000;
pub const O_CLOEXEC = 0o2000000;
pub const O_DIRECTORY = 0o200000;
pub const EINTR = 4;
pub const EAGAIN = 11;
pub const EACCES = 13;

pub fn errno() c_int {
    return __errno_location().*;
}

/// A path as a null-terminated string on the stack.
pub fn pathZ(buf: *[std.fs.max_path_bytes]u8, path: []const u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn exists(path: []const u8) bool {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const z = pathZ(&b, path) orelse return false;
    return access(z.ptr, 0) == 0;
}

pub fn env(name: [:0]const u8) ?[]const u8 {
    const v = getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}

pub const ReadError = error{ NotFound, AccessDenied, TooBig, Failed, OutOfMemory };

/// Whole file into memory. A missing file is `error.NotFound`.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8, max: usize) ReadError![]u8 {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const z = pathZ(&b, path) orelse return error.Failed;
    const fd = open(z.ptr, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return switch (errno()) {
        2 => error.NotFound,
        EACCES => error.AccessDenied,
        else => error.Failed,
    };
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return error.Failed;
        }
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max) return error.TooBig;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

pub const WriteError = error{ AccessDenied, Failed };

pub fn writeAllFd(fd: c_int, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return error.Failed;
        }
        rest = rest[@intCast(n)..];
    }
}

extern fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;
extern fn getpid() c_int;
extern fn fchmod(fd: c_int, mode: c_uint) c_int;
extern fn fchown(fd: c_int, owner: c_uint, group: c_uint) c_int;
extern fn fsync(fd: c_int) c_int;
extern fn flock(fd: c_int, operation: c_int) c_int;
const O_EXCL = 0o200;
const LOCK_EX = 2;

/// The file `path` names, following symbolic links, so that writing replaces
/// the file a link points at and leaves the link.
fn followLinks(path: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (path.len >= out.len) return null;
    @memcpy(out[0..path.len], path);
    var len = path.len;
    for (0..16) |_| {
        var zb: [std.fs.max_path_bytes]u8 = undefined;
        const z = pathZ(&zb, out[0..len]) orelse return null;
        var target: [std.fs.max_path_bytes]u8 = undefined;
        const n = readlink(z.ptr, &target, target.len);
        if (n < 0) return out[0..len]; // not a link, or not there yet
        const t = target[0..@intCast(n)];
        // A relative target is relative to the link's directory.
        const keep = if (t.len > 0 and t[0] == '/') 0 else if (std.mem.lastIndexOfScalar(u8, out[0..len], '/')) |i| i + 1 else 0;
        if (keep + t.len >= out.len) return null;
        @memcpy(out[keep..][0..t.len], t);
        len = keep + t.len;
    }
    return null; // a loop of links
}

fn directoryOf(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    return if (i == 0) "/" else path[0..i];
}

fn openDirectory(path: []const u8) c_int {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const z = pathZ(&b, directoryOf(path)) orelse return -1;
    return open(z.ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
}

/// Holds off others who read, change and write files in the directory of
/// `path`, until `close` on the descriptor. Null when it cannot be locked, as
/// when the directory cannot be opened; the write that follows will say why.
pub fn lockDirectoryOf(path: []const u8) ?c_int {
    const fd = openDirectory(path);
    if (fd < 0) return null;
    while (flock(fd, LOCK_EX) != 0) {
        if (errno() == EINTR) continue;
        _ = close(fd);
        return null;
    }
    return fd;
}

fn writeError() WriteError {
    // EPERM, EACCES, EROFS
    return if (errno() == EACCES or errno() == 1 or errno() == 30) error.AccessDenied else error.Failed;
}

/// Write `data` to `path` through a temporary file and a rename, so a crash or
/// a full disk never leaves a half-written configuration. A file that is
/// replaced keeps its mode and owner; a new one is mode 0644 less the umask.
pub fn writeFileAtomic(path: []const u8, data: []const u8) WriteError!void {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const target = followLinks(path, &rb) orelse return error.Failed;
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    const final = pathZ(&b1, target) orelse return error.Failed;
    var tmp_name: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_name, "{s}.{d}.tmp", .{ target, getpid() }) catch return error.Failed;
    const tmp = pathZ(&b2, tmp_path) orelse return error.Failed;

    const linux = std.os.linux;
    var old: linux.Statx = undefined;
    const exists_already = linux.errno(linux.statx(linux.AT.FDCWD, final.ptr, 0, .{ .MODE = true, .UID = true, .GID = true }, &old)) == .SUCCESS;

    // Only ever a file of our own making: O_EXCL refuses one that is there,
    // a symbolic link included. One left by a crashed run goes first.
    _ = unlink(tmp.ptr);
    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return writeError();
    var ok = false;
    defer if (!ok) {
        _ = unlink(tmp.ptr);
    };
    {
        defer if (!ok) {
            _ = close(fd);
        };
        writeAllFd(fd, data) catch return error.Failed;
        if (exists_already) {
            // Only root can give a file away; anyone else owns what they replace.
            _ = fchown(fd, old.uid, old.gid);
            if (fchmod(fd, old.mode & 0o7777) != 0) return writeError();
        }
        // The data must be on disk before the name points at it.
        if (fsync(fd) != 0) return error.Failed;
        ok = true;
    }
    ok = false;
    if (close(fd) != 0) return error.Failed;
    if (rename(tmp.ptr, final.ptr) != 0) return writeError();
    ok = true;
    const dir = openDirectory(target);
    if (dir >= 0) {
        _ = fsync(dir);
        _ = close(dir);
    }
}

pub fn makeDir(path: []const u8) void {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const z = pathZ(&b, path) orelse return;
    _ = mkdir(z.ptr, 0o755);
}

/// Print to standard output or error. Failures are ignored: there is nowhere
/// left to report them.
pub fn print(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        // A long value, or a log tail in a report: all of it is printed.
        const long = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
        defer std.heap.page_allocator.free(long);
        writeAllFd(fd, long) catch {};
        return;
    };
    writeAllFd(fd, s) catch {};
}

// ---- logging -----------------------------------------------------------------

/// The runtime level; `[console] log-level` sets it, live. Messages go to
/// standard error, which the init system collects (dinit's log, the journal).
pub var log_level: std.log.Level = .info;
/// The VT this process is on, shown in every line; 0 for the config tool.
pub var log_vt: u32 = 0;

const Timespec = extern struct { sec: c_long, nsec: c_long };
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;

/// A copy of every log line goes to a file under /run, so a report can include
/// what the console said even when the init system's log is out of reach.
var log_fd: c_int = -1;
var log_bytes: usize = 0;
const log_cap = 1 << 20;

/// Start `<dir>/tty<vt>.log`, keeping the previous one as `.log.1`.
pub fn openLogFile(dir: []const u8, vt: u32) void {
    var pb: [96]u8 = undefined;
    var ob: [100]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/tty{d}.log", .{ dir, vt }) catch return;
    const old = std.fmt.bufPrint(&ob, "{s}.1", .{path}) catch return;
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    makeDir(dir);
    const pz = pathZ(&b1, path) orelse return;
    const oz = pathZ(&b2, old) orelse return;
    _ = rename(pz.ptr, oz.ptr);
    log_fd = open(pz.ptr, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, @as(c_uint, 0o644));
}

pub fn parseLevel(text: []const u8) std.log.Level {
    if (std.mem.eql(u8, text, "error")) return .err;
    if (std.mem.eql(u8, text, "warn")) return .warn;
    if (std.mem.eql(u8, text, "debug")) return .debug;
    return .info;
}

/// `std_options.logFn`: `dkconsole[tty1] [   12.345] info(drm): message`.
/// The time is seconds since boot, as in dmesg, so lines can be lined up with
/// the kernel's.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) > @backingInt(log_level)) return;
    var buf: [1024]u8 = undefined;
    var ts: Timespec = undefined;
    _ = clock_gettime(7, &ts); // CLOCK_BOOTTIME
    var w: std.Io.Writer = .fixed(&buf);
    w.print("dkconsole", .{}) catch {};
    if (log_vt != 0) w.print("[tty{d}]", .{log_vt}) catch {};
    w.print(" [{d:>6}.{d:0>3}] {s}", .{ @as(u64, @intCast(ts.sec)), @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000))), @tagName(level) }) catch {};
    if (scope != .default) w.print("({s})", .{@tagName(scope)}) catch {};
    w.print(": " ++ fmt ++ "\n", args) catch {};
    writeAllFd(2, w.buffered()) catch {};
    if (log_fd >= 0 and log_bytes < log_cap) {
        writeAllFd(log_fd, w.buffered()) catch {};
        log_bytes += w.buffered().len;
    }
}

const testing = std.testing;
extern fn symlink(target: [*:0]const u8, link: [*:0]const u8) c_int;
extern fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

fn modeOf(path: [*:0]const u8, follow: bool) u16 {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    _ = linux.statx(linux.AT.FDCWD, path, if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW, .{ .MODE = true, .TYPE = true }, &st);
    return st.mode;
}

test "writing a file keeps its mode and the link that names it" {
    var nb: [64]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&nb, "/tmp/dkconsole-write-{d}", .{getpid()}, 0);
    makeDir(root);
    var rb: [96]u8 = undefined;
    var lb: [96]u8 = undefined;
    const real = try std.fmt.bufPrintSentinel(&rb, "{s}/real.toml", .{root}, 0);
    const link = try std.fmt.bufPrintSentinel(&lb, "{s}/config.toml", .{root}, 0);
    defer {
        _ = unlink(link.ptr);
        _ = unlink(real.ptr);
        _ = std.os.linux.rmdir(root.ptr);
    }
    try writeFileAtomic(real, "one");
    try testing.expectEqual(@as(c_int, 0), chmod(real.ptr, 0o600));
    try testing.expectEqual(@as(c_int, 0), symlink("real.toml", link.ptr));

    const lock = lockDirectoryOf(link).?;
    defer _ = close(lock);
    try writeFileAtomic(link, "two");

    try testing.expectEqual(@as(u16, std.os.linux.S.IFLNK), modeOf(link.ptr, false) & std.os.linux.S.IFMT);
    try testing.expectEqual(@as(u16, 0o600), modeOf(real.ptr, true) & 0o7777);
    const text = try readFile(testing.allocator, real, 16);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("two", text);
}
