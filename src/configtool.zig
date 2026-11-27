// SPDX-License-Identifier: GPL-2.0-or-later
//! `dkconsole config ...` (SPEC.md 5.11, *Configuration tools*): the text
//! front end to /etc/dkconsole/config.toml. It follows 6.1's static-files rule,
//! so setting a value that is already in effect writes nothing.

const std = @import("std");
const termcore = @import("termcore");
const toml = @import("toml");
const ini = @import("tomlcfg.zig");
const config = @import("config.zig");
const psf = @import("psf.zig");
const fontscan = @import("fontscan.zig");
const ttf = @import("ttf.zig");
const sys = @import("sys.zig");

const out_fd = 1;
const err_fd = 2;

pub fn etcPath() []const u8 {
    return sys.env("DKCONSOLE_CONFIG") orelse "/etc/dkconsole/config.toml";
}

pub fn defaultsPath(buf: []u8) []const u8 {
    const dir = sys.env("DKCONSOLE_DATA_DIR") orelse "/usr/share/dkconsole";
    return std.fmt.bufPrint(buf, "{s}/config.example.toml", .{dir}) catch "";
}

/// Why a settings file could not be used, ready to print.
pub const Problem = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Problem) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Problem, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&self.buf);
        w.print(fmt, args) catch {};
        self.len = w.buffered().len;
    }
};

/// Loads a file as a document. A missing file is an empty document; anything
/// else that goes wrong is an error, described in `problem`. Only a missing
/// file may be treated as empty: writing back over one that merely could not
/// be read would erase it.
pub fn loadDoc(allocator: std.mem.Allocator, path: []const u8, problem: *Problem) error{Unusable}!ini.Document {
    const text = sys.readFile(allocator, path, 1 << 20) catch |e| switch (e) {
        error.NotFound => return ini.Document.init(allocator),
        else => {
            problem.set("cannot read it: {s}", .{@errorName(e)});
            return error.Unusable;
        },
    };
    defer allocator.free(text);
    var diag: toml.Diagnostic = .{};
    return ini.Document.parseDiag(allocator, text, &diag) catch |e| {
        if (diag.line > 0) problem.set("line {d}, column {d}: {s}", .{ diag.line, diag.column, diag.message }) else problem.set("{s}", .{@errorName(e)});
        return error.Unusable;
    };
}

const usage =
    \\usage: dkconsole config list [--vt N]
    \\       dkconsole config get [--vt N] KEY
    \\       dkconsole config set [--vt N] KEY VALUE
    \\       dkconsole config reset [--vt N] KEY
    \\       dkconsole config fonts
    \\
;

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        sys.print(err_fd, "{s}", .{usage});
        return 2;
    }
    const cmd = args[0];
    var rest = args[1..];
    var vt: u32 = 0;
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--vt")) {
        vt = std.fmt.parseInt(u32, rest[1], 10) catch {
            sys.print(err_fd, "dkconsole: --vt needs a number\n", .{});
            return 2;
        };
        if (vt == 0 or vt > 63) {
            sys.print(err_fd, "dkconsole: --vt must be 1 to 63\n", .{});
            return 2;
        }
        rest = rest[2..];
    }

    const changes = std.mem.eql(u8, cmd, "set") or std.mem.eql(u8, cmd, "reset");
    // From reading to writing, so that two changes do not undo each other.
    var lock: ?c_int = null;
    defer if (lock) |fd| {
        _ = sys.close(fd);
    };
    if (changes) {
        const path = etcPath();
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
            if (i > 0 and sys.geteuid() == 0) sys.makeDir(path[0..i]);
        }
        lock = sys.lockDirectoryOf(path);
    }
    var broken = false;
    var etc = loadOrReport(allocator, etcPath(), &broken);
    defer etc.deinit();
    if (broken and changes) {
        sys.print(err_fd, "dkconsole: nothing was changed; repair the file first\n", .{});
        return 1;
    }
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    var defs_broken = false;
    var defs = loadOrReport(allocator, defaultsPath(&dbuf), &defs_broken);
    defer defs.deinit();
    const layers: config.Layers = .{ .etc = &etc, .defaults = &defs };

    // With an unreadable file these show what is left, and fail.
    if (std.mem.eql(u8, cmd, "list") and rest.len == 0) return @max(list(layers, vt), @intFromBool(broken));
    if (std.mem.eql(u8, cmd, "get") and rest.len == 1) return @max(get(layers, vt, rest[0]), @intFromBool(broken));
    if (std.mem.eql(u8, cmd, "set") and rest.len == 2) return set(allocator, &etc, vt, rest[0], rest[1]);
    if (std.mem.eql(u8, cmd, "reset") and rest.len == 1) return reset(allocator, &etc, vt, rest[0]);
    if (std.mem.eql(u8, cmd, "fonts") and rest.len == 0) return fonts(allocator);
    sys.print(err_fd, "{s}", .{usage});
    return 2;
}

fn loadOrReport(allocator: std.mem.Allocator, path: []const u8, broken: *bool) ini.Document {
    var problem: Problem = .{};
    return loadDoc(allocator, path, &problem) catch {
        sys.print(err_fd, "dkconsole: {s}: {s}\n", .{ path, problem.text() });
        broken.* = true;
        return ini.Document.init(allocator);
    };
}

fn sourceName(s: config.Source) []const u8 {
    return switch (s) {
        .default => "default",
        .system_defaults => "config.example.toml",
        .etc => "/etc",
        .vt => "[vt]",
    };
}

fn list(layers: config.Layers, vt: u32) u8 {
    for (&config.keys) |*k| {
        const v = config.lookup(layers, vt, k);
        sys.print(out_fd, "{s} = {s}    ({s})\n", .{ k.name, v.text, sourceName(v.source) });
    }
    return 0;
}

fn get(layers: config.Layers, vt: u32, name: []const u8) u8 {
    const k = config.find(name) orelse return unknownKey(name);
    sys.print(out_fd, "{s}\n", .{config.lookup(layers, vt, k).text});
    return 0;
}

fn unknownKey(name: []const u8) u8 {
    sys.print(err_fd, "dkconsole: unknown key '{s}'. Keys:", .{name});
    for (&config.keys) |k| sys.print(err_fd, " {s}", .{k.name});
    sys.print(err_fd, "\n", .{});
    return 1;
}

/// Why a value is not acceptable, beyond the type check: files must exist and
/// load, as SPEC.md 5.11 requires.
fn deepCheck(allocator: std.mem.Allocator, key: *const config.Key, value: []const u8) ?[]const u8 {
    if (config.check(key, value)) |why| return why;
    if (std.mem.eql(u8, key.name, "font")) {
        if (value.len > 0 and !fontLoads(allocator, value)) return "font file not found, or not a PSF or TrueType font";
    } else if (std.mem.eql(u8, key.name, "fallback-fonts")) {
        var it = std.mem.tokenizeAny(u8, value, ", ");
        while (it.next()) |f| if (!fontLoads(allocator, f)) return "a listed font file is not found, or not a PSF or TrueType font";
    }
    return null;
}

fn fontLoads(allocator: std.mem.Allocator, name: []const u8) bool {
    for (psf.builtin_data) |b| if (std.mem.eql(u8, b.name, name)) return true;
    const data = sys.readFile(allocator, name, 32 << 20) catch return false;
    defer allocator.free(data);
    if (ttf.looksLikeTrueType(data)) {
        var face = ttf.Face.init(allocator, data, 16) catch return false;
        face.deinit();
        return true;
    }
    var f = psf.Font.parse(allocator, data) catch return false;
    f.deinit(allocator);
    return true;
}

fn groupFor(buf: []u8, vt: u32) []const u8 {
    if (vt == 0) return config.group;
    return std.fmt.bufPrint(buf, "vt:{d}", .{vt}) catch config.group;
}

fn save(allocator: std.mem.Allocator, doc: *ini.Document) u8 {
    const text = doc.toOwnedString(allocator) catch |e| {
        switch (e) {
            error.OutOfMemory => sys.print(err_fd, "dkconsole: out of memory\n", .{}),
            error.InvalidValue => sys.print(err_fd, "dkconsole: not changed: a value cannot be written as TOML (is it valid UTF-8?)\n", .{}),
            else => sys.print(err_fd, "dkconsole: not changed: the settings cannot be written ({s})\n", .{@errorName(e)}),
        }
        return 1;
    };
    defer allocator.free(text);
    const path = etcPath();
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| sys.makeDir(path[0..i]);
    sys.writeFileAtomic(path, text) catch |e| {
        if (e == error.AccessDenied or sys.geteuid() != 0) {
            sys.print(err_fd, "dkconsole: changing the console settings needs root (cannot write {s}). Try: sudo dkconsole config ...\n", .{path});
        } else sys.print(err_fd, "dkconsole: cannot write {s}\n", .{path});
        return 1;
    };
    return 0;
}

/// Sets `key` under its present name, in place of its older one. False when
/// the file already says so, under either name.
fn assign(doc: *ini.Document, group: []const u8, key: *const config.Key, value: []const u8) !bool {
    if (key.alias) |old| {
        if (doc.get(group, key.name) == null) {
            if (doc.get(group, old)) |v| if (std.mem.eql(u8, v, value)) return false;
        }
        const removed = doc.remove(group, old);
        return try doc.set(group, key.name, value) or removed;
    }
    return doc.set(group, key.name, value);
}

fn unassign(doc: *ini.Document, group: []const u8, key: *const config.Key) bool {
    const removed = doc.remove(group, key.name);
    const old_removed = if (key.alias) |old| doc.remove(group, old) else false;
    return removed or old_removed;
}

fn set(allocator: std.mem.Allocator, etc: *ini.Document, vt: u32, name: []const u8, value: []const u8) u8 {
    const k = config.find(name) orelse return unknownKey(name);
    if (deepCheck(allocator, k, value)) |why| {
        sys.print(err_fd, "dkconsole: {s}: '{s}' refused: {s}\n", .{ name, value, why });
        return 1;
    }
    var gbuf: [24]u8 = undefined;
    const changed = assign(etc, groupFor(&gbuf, vt), k, value) catch |e| {
        switch (e) {
            error.InvalidDocument => sys.print(err_fd, "dkconsole: {s}: [{s}] is not a table of settings there; nothing was changed\n", .{ etcPath(), groupFor(&gbuf, vt) }),
            else => sys.print(err_fd, "dkconsole: out of memory\n", .{}),
        }
        return 1;
    };
    if (!changed) return 0; // already in effect: write nothing
    return save(allocator, etc);
}

fn reset(allocator: std.mem.Allocator, etc: *ini.Document, vt: u32, name: []const u8) u8 {
    const k = config.find(name) orelse return unknownKey(name);
    var gbuf: [24]u8 = undefined;
    if (!unassign(etc, groupFor(&gbuf, vt), k)) return 0;
    return save(allocator, etc);
}

fn fonts(allocator: std.mem.Allocator) u8 {
    sys.print(out_fd, "Built in:\n", .{});
    for (psf.builtin_data) |b| {
        var f = psf.Font.parse(allocator, b.data) catch continue;
        defer f.deinit(allocator);
        sys.print(out_fd, "  {s}  ({d}x{d})\n", .{ b.name, f.width, f.height });
    }
    const found = fontscan.scan(allocator) catch &.{};
    if (found.len > 0) sys.print(out_fd, "On this system (PSF, and monospace TrueType):\n", .{});
    for (found) |p| sys.print(out_fd, "  {s}\n", .{p});
    sys.print(out_fd, "Fonts compressed with gzip (.psf.gz) must be unpacked first.\n", .{});
    return 0;
}

test "only a missing settings file counts as an empty one" {
    const a = std.testing.allocator;
    var problem: Problem = .{};
    var missing = try loadDoc(a, "/nonexistent/dkconsole.toml", &problem);
    missing.deinit();
    // A directory exists and cannot be read as a file.
    try std.testing.expectError(error.Unusable, loadDoc(a, "/proc", &problem));
    try std.testing.expect(problem.len > 0);
    // Not TOML: the reason names the line.
    try std.testing.expectError(error.Unusable, loadDoc(a, "/proc/version", &problem));
    try std.testing.expect(std.mem.startsWith(u8, problem.text(), "line 1, column "));
}
