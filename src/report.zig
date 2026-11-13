//! `dkconsole report` and `dkconsole recovery ...` (SPEC.md 5.11, *Fallback*):
//! what to run on a machine to say what the console saw and why it did what
//! it did, and how to clear the crash latch afterwards.

const std = @import("std");
const build_options = @import("build_options");
const configtool = @import("configtool.zig");
const drm = @import("drm.zig");
const fallback = @import("fallback.zig");
const issue = @import("issue.zig");
const sys = @import("sys.zig");

const out = 1;
const err = 2;

fn heading(title: []const u8) void {
    sys.print(out, "\n==== {s}\n", .{title});
}

/// The last `n` lines of `text`.
pub fn tailLines(text: []const u8, n: usize) []const u8 {
    var end = text.len;
    if (end > 0 and text[end - 1] == '\n') end -= 1;
    var count: usize = 0;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            count += 1;
            if (count == n) return text[i..end];
        }
    }
    return text[0..end];
}

fn showFile(allocator: std.mem.Allocator, path: []const u8, max_lines: usize) void {
    const text = sys.readFile(allocator, path, 4 << 20) catch |e| {
        sys.print(out, "{s}: {s}\n", .{ path, @errorName(e) });
        return;
    };
    defer allocator.free(text);
    sys.print(out, "--- {s}{s}\n{s}\n", .{ path, if (tailLines(text, max_lines).len < std.mem.trimEnd(u8, text, "\n").len) " (last lines)" else "", tailLines(text, max_lines) });
}

/// Device names and handlers only: /proc/bus/input/devices also holds serial numbers.
fn showInput(allocator: std.mem.Allocator) void {
    const text = sys.readFile(allocator, "/proc/bus/input/devices", 256 << 10) catch |e| {
        sys.print(out, "/proc/bus/input/devices: {s}\n", .{@errorName(e)});
        return;
    };
    defer allocator.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "N: ") or std.mem.startsWith(u8, l, "H: ")) sys.print(out, "{s}\n", .{l});
    }
}

fn showDrm(allocator: std.mem.Allocator) void {
    var n: u32 = 0;
    var found = false;
    while (n < 8) : (n += 1) {
        var pb: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "/dev/dri/card{d}", .{n}, 0) catch continue;
        const fd = sys.open(path.ptr, sys.O_RDWR | sys.O_CLOEXEC);
        if (fd < 0) {
            if (sys.errno() != 2) sys.print(out, "{s}: cannot open, errno {d}\n", .{ path, sys.errno() });
            continue;
        }
        found = true;
        defer _ = sys.close(fd);
        var dev: drm.Device = .{ .fd = fd };
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        dev.describe(allocator, &aw.writer) catch {};
        sys.print(out, "{s}:\n", .{path});
        var it = std.mem.splitScalar(u8, aw.written(), '\n');
        while (it.next()) |l| if (l.len > 0) sys.print(out, "  {s}\n", .{l});
    }
    if (!found) sys.print(out, "no /dev/dri/card* device (no kernel display driver, or no permission)\n", .{});
}

pub fn report(allocator: std.mem.Allocator) u8 {
    var uts: issue.Uts = .{};
    const si = uts.system("");
    heading("dkconsole");
    sys.print(out, "version {s}\nkernel {s} {s} {s}\neuid {d}\n", .{ build_options.version, si.sysname, si.release, si.machine, std.c.geteuid() });
    if (std.c.geteuid() != 0) sys.print(out, "(not root: some devices below may be unreadable; run again with sudo)\n", .{});
    if (sys.readFile(allocator, "/etc/os-release", 16 << 10)) |osr| {
        defer allocator.free(osr);
        sys.print(out, "os {s}\n", .{issue.osReleaseValue(osr, "PRETTY_NAME") orelse "unknown"});
    } else |_| {}
    showFile(allocator, "/proc/cmdline", 5);

    heading("settings in effect (dkconsole config list)");
    _ = configtool.run(allocator, &.{"list"});

    heading("display (drm)");
    showDrm(allocator);

    heading("input devices");
    showInput(allocator);

    heading("virtual terminals");
    showFile(allocator, "/sys/class/tty/tty0/active", 1);
    recoveryStatus(allocator, 0);

    heading("console log");
    var n: u32 = 1;
    var any = false;
    while (n <= 63) : (n += 1) {
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/tty{d}.log", .{ fallback.state_dir, n }) catch continue;
        if (!sys.exists(path)) continue;
        any = true;
        showFile(allocator, path, 150);
        var ob: [72]u8 = undefined;
        const old = std.fmt.bufPrint(&ob, "{s}.1", .{path}) catch continue;
        if (sys.exists(old)) showFile(allocator, old, 40);
    }
    if (!any) sys.print(out, "no log under {s} (the console has not run since boot)\n", .{fallback.state_dir});
    sys.print(out, "\nCheck this for anything you do not want to share (the kernel command line, device names) before posting it.\n", .{});
    return 0;
}

/// Print the crash counter of one VT, or of every VT that has one when `vt` is 0.
pub fn recoveryStatus(allocator: std.mem.Allocator, vt: u32) void {
    var shown = false;
    var n: u32 = 1;
    while (n <= 63) : (n += 1) {
        if (vt != 0 and n != vt) continue;
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/tty{d}.starts", .{ fallback.state_dir, n }) catch continue;
        if (!sys.exists(path) and vt == 0) continue;
        shown = true;
        const starts = fallback.readCounter(allocator, n);
        const latched = fallback.decide(starts).fall_back;
        sys.print(out, "tty{d}: {d} start(s) counted; {s}\n", .{
            n,                                                                                                   starts,
            if (latched) "the next start goes straight to the plain getty (latched until `dkconsole recovery reset` or reboot)" else "the console will start normally",
        });
    }
    if (!shown) sys.print(out, "no VT has crashed or started recently\n", .{});
}

/// `dkconsole recovery status [--vt N]` and `recovery reset --vt N`.
pub fn recovery(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const usage = "usage: dkconsole recovery status [--vt N]\n       dkconsole recovery reset --vt N\n";
    if (args.len == 0) {
        sys.print(err, "{s}", .{usage});
        return 2;
    }
    var vt: u32 = 0;
    if (args.len == 3 and std.mem.eql(u8, args[1], "--vt")) {
        vt = std.fmt.parseInt(u32, args[2], 10) catch 0;
        if (vt == 0 or vt > 63) {
            sys.print(err, "dkconsole: --vt must be 1 to 63\n", .{});
            return 2;
        }
    } else if (args.len != 1) {
        sys.print(err, "{s}", .{usage});
        return 2;
    }
    if (std.mem.eql(u8, args[0], "status")) {
        recoveryStatus(allocator, vt);
        return 0;
    }
    if (std.mem.eql(u8, args[0], "reset") and vt != 0) {
        if (std.c.geteuid() != 0) {
            sys.print(err, "dkconsole: recovery reset needs root\n", .{});
            return 1;
        }
        // Only the counter is touched: a console that is running keeps running.
        fallback.writeCounter(vt, 0);
        sys.print(out, "tty{d}: crash counter cleared\n", .{vt});
        return 0;
    }
    sys.print(err, "{s}", .{usage});
    return 2;
}

test "tail keeps the last lines" {
    try std.testing.expectEqualStrings("c\nd", tailLines("a\nb\nc\nd\n", 2));
    try std.testing.expectEqualStrings("a\nb", tailLines("a\nb", 5));
    try std.testing.expectEqualStrings("", tailLines("", 3));
}
