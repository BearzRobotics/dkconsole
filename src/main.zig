//! dkconsole: the Linux text console, rebuilt (SPEC.md 5.11).
//!
//!     dkconsole --vt N          run on virtual terminal N (what init starts)
//!     dkconsole config ...      read and change /etc/dkconsole/config.toml

const std = @import("std");
const configtool = @import("configtool.zig");
const console = @import("console.zig");
const report = @import("report.zig");
const sys = @import("sys.zig");
const vt = @import("vt.zig");

// The compiled-in level lets everything through; `sys.log_level` filters while
// running, so `[console] log-level=debug` needs no rebuild.
/// A failed safety check anywhere, the terminal parser included, gives the VT
/// back before the process ends.
pub const panic = std.debug.FullPanic(panicked);

fn panicked(message: []const u8, first_address: ?usize) noreturn {
    vt.restoreAfterPanic();
    std.debug.defaultPanic(message, first_address);
}

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = sys.logFn };

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    for (init.args.vector[1..]) |a| try args.append(arena, std.mem.span(a));

    if (args.items.len >= 1 and std.mem.eql(u8, args.items[0], "config")) {
        std.process.exit(configtool.run(arena, args.items[1..]));
    }
    if (args.items.len == 1 and std.mem.eql(u8, args.items[0], "report")) std.process.exit(report.report(arena));
    if (args.items.len >= 1 and std.mem.eql(u8, args.items[0], "recovery")) std.process.exit(report.recovery(arena, args.items[1..]));
    if (args.items.len == 1 and (std.mem.eql(u8, args.items[0], "--version") or std.mem.eql(u8, args.items[0], "version"))) {
        sys.print(1, "dkconsole {s}\n", .{@import("build_options").version});
        std.process.exit(0);
    }
    if (args.items.len == 2 and std.mem.eql(u8, args.items[0], "--vt")) {
        const n = std.fmt.parseInt(u32, args.items[1], 10) catch 0;
        // The console runs for months, reloading fonts and keymaps as it goes:
        // it needs an allocator that takes memory back. The arena above suits
        // the commands that run once and exit.
        if (n >= 1 and n <= 63) std.process.exit(console.run(std.heap.c_allocator, .{ .vt = n }));
    }
    const usage =
        \\usage: dkconsole --vt N          run on virtual terminal N
        \\       dkconsole config ...      change the console settings
        \\       dkconsole report          what the console sees, for a bug report
        \\       dkconsole recovery ...    crash record: status, reset --vt N
        \\       dkconsole version
        \\
    ;
    _ = std.c.write(2, usage.ptr, usage.len);
    std.process.exit(2);
}

test {
    // Only the files named here run their tests. `truetype.zig` is its own
    // module (see build.zig).
    _ = @import("config.zig");
    _ = @import("tomlcfg.zig");
    _ = @import("sample.zig");
    _ = @import("fontscan.zig");
    _ = @import("psf.zig");
    _ = @import("ttf.zig");
    _ = @import("sys.zig");
    _ = @import("issue.zig");
    _ = @import("report.zig");
    _ = @import("configtool.zig");
    _ = @import("kbd.zig");
    _ = @import("drm.zig");
    _ = @import("evdev.zig");
    _ = @import("vt.zig");
    _ = @import("fallback.zig");
    _ = @import("render.zig");
    _ = @import("console.zig");
}
