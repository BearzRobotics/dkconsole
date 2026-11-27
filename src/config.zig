//! Console settings (SPEC.md 5.11, *Configuration*). One table describes every
//! key, so the loader, `dkconsole config list/get/set/reset` and the
//! Settings page all agree on names, defaults and what is valid.

const std = @import("std");
const termcore = @import("termcore");
const toml = @import("toml");
const ini = @import("tomlcfg.zig");
const drm = @import("drm.zig");

pub const group = "console";

pub const Kind = enum { string, int, boolean, list };

pub const Key = struct {
    name: []const u8,
    /// An older name that still works.
    alias: ?[]const u8 = null,
    kind: Kind,
    default: []const u8,
    /// Inclusive limits for `.int`.
    min: i64 = 0,
    max: i64 = 0,
    /// Allowed values for a `.string` that is a choice; empty means any.
    choices: []const []const u8 = &.{},
};

pub const color_schemes = termcore.schemes.names;

pub const keys = [_]Key{
    .{ .name = "font", .kind = .string, .default = "" },
    .{ .name = "fallback-fonts", .kind = .list, .default = "" },
    .{ .name = "font-size", .kind = .int, .default = "0", .min = 0, .max = 128 },
    .{ .name = "scale", .kind = .int, .default = "1", .min = 1, .max = 2 },
    .{ .name = "mode", .kind = .string, .default = "" },
    .{ .name = "display", .kind = .string, .default = "" },
    .{ .name = "login-program", .kind = .string, .default = "" },
    .{ .name = "issue-file", .kind = .string, .default = "/etc/issue" },
    // `color-scheme`, `cursor-style`, `scrollback-lines` and `osc52` are the
    // terminal settings DKTerm shares; see `Settings.resolve`.
    .{ .name = "color-scheme", .alias = "colors", .kind = .string, .default = "campbell", .choices = &color_schemes },
    .{ .name = "cursor-style", .kind = .string, .default = "block", .choices = &.{ "block", "bar", "underline" } },
    .{ .name = "scrollback-lines", .kind = .int, .default = "2000", .min = 0, .max = 100000 },
    .{ .name = "cursor-blink", .kind = .boolean, .default = "false" },
    .{ .name = "fallback", .kind = .string, .default = "/sbin/agetty --noclear tty%N linux" },
    // Off at a login console: any output, a displayed file included, could
    // otherwise choose what the next paste types.
    .{ .name = "osc52", .kind = .boolean, .default = "false" },
    .{ .name = "log-level", .kind = .string, .default = "info", .choices = &.{ "error", "warn", "info", "debug" } },
    .{ .name = "image-memory", .kind = .int, .default = "32", .min = 0, .max = 4096 },
};

pub fn find(name: []const u8) ?*const Key {
    for (&keys) |*k| {
        if (std.mem.eql(u8, k.name, name)) return k;
        if (k.alias) |a| if (std.mem.eql(u8, a, name)) return k;
    }
    return null;
}

/// Shared terminal settings this console does not act on: it runs `login`,
/// never a shell or a command of the user's choosing.
pub const unused_shared_keys = [_][]const u8{ "command", "directory" };

/// `group`'s value of `key` under its name or its older one, if it passes.
fn valid(doc: *const ini.Document, group_name: []const u8, key: *const Key) ?[]const u8 {
    for ([_]?[]const u8{ key.name, key.alias }) |name| {
        const v = doc.get(group_name, name orelse continue) orelse continue;
        if (check(key, v) == null) return v;
    }
    return null;
}

pub const Source = enum { default, system_defaults, etc, vt };

pub const Value = struct { text: []const u8, source: Source };

/// Why a value was refused; `check` returns null for a good one.
pub fn check(key: *const Key, value: []const u8) ?[]const u8 {
    switch (key.kind) {
        .string, .list => {
            if (key.choices.len > 0) {
                for (key.choices) |c| if (std.mem.eql(u8, c, value)) return null;
                return "not one of the known choices";
            }
            if (std.mem.eql(u8, key.name, "mode") and drm.ModeRequest.parse(value) == null) return "expected WIDTHxHEIGHT or WIDTHxHEIGHT@HZ";
            if (std.mem.eql(u8, key.name, "fallback") and (value.len == 0 or value[0] != '/')) return "must be a command starting with an absolute path";
            if (std.mem.eql(u8, key.name, "login-program") and value.len > 0 and value[0] != '/') return "must be an absolute path";
            if (std.mem.eql(u8, key.name, "display") and std.mem.indexOfAny(u8, value, " /\t") != null) return "expected a connector name such as HDMI-A-1";
            if (std.mem.eql(u8, key.name, "issue-file") and value.len > 0 and value[0] != '/') return "must be an absolute path";
            return null;
        },
        .int => {
            const n = std.fmt.parseInt(i64, value, 10) catch return "not a whole number";
            if (n < key.min or n > key.max) return "out of range";
            return null;
        },
        .boolean => {
            if (ini.parseBool(value) == null) return "must be true or false";
            return null;
        },
    }
}

/// The layers a value can come from, most specific first. Either document may
/// be absent (no file).
pub const Layers = struct {
    etc: ?*const ini.Document = null,
    defaults: ?*const ini.Document = null,
};

/// Look up `key` for `vt` (0 = no VT): `[vt:N]` in /etc, then `[console]` in
/// /etc, then the shipped defaults file, then the compiled-in default. A value
/// that fails `check` is skipped, so a typo never breaks the console.
pub fn lookup(layers: Layers, vt: u32, key: *const Key) Value {
    var gbuf: [24]u8 = undefined;
    const vt_group = std.fmt.bufPrint(&gbuf, "vt:{d}", .{vt}) catch "";
    if (layers.etc) |d| {
        if (vt != 0) if (valid(d, vt_group, key)) |v| return .{ .text = v, .source = .vt };
        if (valid(d, group, key)) |v| return .{ .text = v, .source = .etc };
    }
    if (layers.defaults) |d| {
        if (valid(d, group, key)) |v| return .{ .text = v, .source = .system_defaults };
    }
    return .{ .text = key.default, .source = .default };
}

/// Reads the shared terminal settings with DKTermCore's reader, so that both
/// terminals take them to mean the same. The values, already layered and
/// checked here, are handed to it as the TOML they stand for.
fn sharedOptions(color_scheme: []const u8, cursor: []const u8, scrollback: u32, osc52: bool) termcore.options.Options {
    // This console's own defaults, for anything that cannot be passed on.
    const base: termcore.options.Options = .{ .color_scheme = "campbell", .scrollback_lines = 2000, .osc52 = false };
    var memory: [8192]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    var doc = toml.Document.init(fixed.allocator()) catch return base;
    defer doc.deinit();
    doc.set(&.{"color-scheme"}, .{ .string = color_scheme }) catch return base;
    doc.set(&.{"cursor-style"}, .{ .string = cursor }) catch return base;
    doc.set(&.{"scrollback-lines"}, .{ .integer = scrollback }) catch return base;
    doc.set(&.{"osc52"}, .{ .boolean = osc52 }) catch return base;
    var read = termcore.options.Options.fromTableOver(doc.root, base);
    // Its strings live in `doc`.
    read.color_scheme = base.color_scheme;
    return read;
}

/// Typed, resolved settings for one VT.
pub const Settings = struct {
    font: []const u8,
    fallback_fonts: []const u8,
    font_size: u32,
    scale: u32,
    mode: drm.ModeRequest,
    mode_text: []const u8,
    display: []const u8,
    login_program: []const u8,
    issue_file: []const u8,
    color_scheme: []const u8,
    cursor: termcore.options.CursorStyle,
    scrollback_lines: u32,
    cursor_blink: bool,
    osc52: bool,
    fallback: []const u8,
    image_memory_mb: u32,
    log_level: []const u8,

    pub fn resolve(layers: Layers, vt: u32) Settings {
        const L = struct {
            fn get(l: Layers, v: u32, name: []const u8) []const u8 {
                return lookup(l, v, find(name).?).text;
            }
            fn int(l: Layers, v: u32, name: []const u8) u32 {
                return std.fmt.parseInt(u32, get(l, v, name), 10) catch 0;
            }
        };
        const shared = sharedOptions(L.get(layers, vt, "color-scheme"), L.get(layers, vt, "cursor-style"), L.int(layers, vt, "scrollback-lines"), ini.parseBool(L.get(layers, vt, "osc52")) orelse false);
        return .{
            .font = L.get(layers, vt, "font"),
            .fallback_fonts = L.get(layers, vt, "fallback-fonts"),
            .font_size = L.int(layers, vt, "font-size"),
            .scale = @max(1, L.int(layers, vt, "scale")),
            .mode = drm.ModeRequest.parse(L.get(layers, vt, "mode")) orelse .{},
            .mode_text = L.get(layers, vt, "mode"),
            .display = L.get(layers, vt, "display"),
            .login_program = L.get(layers, vt, "login-program"),
            .issue_file = L.get(layers, vt, "issue-file"),
            // A name `check` has passed, so it is the one `shared` read.
            .color_scheme = L.get(layers, vt, "color-scheme"),
            .cursor = shared.cursor,
            .scrollback_lines = shared.scrollback_lines,
            .cursor_blink = ini.parseBool(L.get(layers, vt, "cursor-blink")) orelse false,
            .osc52 = shared.osc52,
            .fallback = L.get(layers, vt, "fallback"),
            .image_memory_mb = L.int(layers, vt, "image-memory"),
            .log_level = L.get(layers, vt, "log-level"),
        };
    }
};

/// Expand `%N` in the fallback command with the VT number.
pub fn expandFallback(out: *std.Io.Writer, template: []const u8, vt: u32) !void {
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] == '%' and i + 1 < template.len and template[i + 1] == 'N') {
            try out.print("{d}", .{vt});
            i += 1;
        } else try out.writeByte(template[i]);
    }
}

const testing = std.testing;

test "defaults when there is no file" {
    const s = Settings.resolve(.{}, 1);
    try testing.expectEqual(@as(u32, 2000), s.scrollback_lines);
    try testing.expectEqualStrings("campbell", s.color_scheme);
    try testing.expect(!s.cursor_blink);
    try testing.expectEqual(@as(u32, 1), s.scale);
}

test "vt section beats console section beats defaults file" {
    var etc = try ini.Document.parse(testing.allocator, "[console]\nfont-size = 24\nscale = 2\n[vt.2]\nfont-size = 32\n");
    defer etc.deinit();
    var defs = try ini.Document.parse(testing.allocator, "[console]\nscrollback-lines = 500\nscale = 1\n");
    defer defs.deinit();
    const layers: Layers = .{ .etc = &etc, .defaults = &defs };
    const s1 = Settings.resolve(layers, 1);
    const s2 = Settings.resolve(layers, 2);
    try testing.expectEqual(@as(u32, 24), s1.font_size);
    try testing.expectEqual(@as(u32, 32), s2.font_size);
    try testing.expectEqual(@as(u32, 2), s2.scale);
    try testing.expectEqual(@as(u32, 500), s1.scrollback_lines);
    try testing.expectEqual(Source.vt, lookup(layers, 2, find("font-size").?).source);
    try testing.expectEqual(Source.system_defaults, lookup(layers, 1, find("scrollback-lines").?).source);
    try testing.expectEqual(Source.default, lookup(layers, 1, find("colors").?).source);
}

test "invalid values fall back instead of failing" {
    var etc = try ini.Document.parse(testing.allocator, "[console]\nscale = 7\ncolors = \"neon\"\ncursor-blink = \"maybe\"\nscrollback-lines = -3\n");
    defer etc.deinit();
    const s = Settings.resolve(.{ .etc = &etc }, 1);
    try testing.expectEqual(@as(u32, 1), s.scale);
    try testing.expectEqualStrings("campbell", s.color_scheme);
    try testing.expect(!s.cursor_blink);
    try testing.expectEqual(@as(u32, 2000), s.scrollback_lines);
}

test "check explains refusals" {
    try testing.expect(check(find("scale").?, "2") == null);
    try testing.expect(check(find("scale").?, "3") != null);
    try testing.expect(check(find("mode").?, "1920x1080@60") == null);
    try testing.expect(check(find("mode").?, "") == null);
    try testing.expect(check(find("mode").?, "huge") != null);
    try testing.expect(check(find("issue-file").?, "/etc/issue.net") == null);
    try testing.expect(check(find("issue-file").?, "issue") != null);
    try testing.expect(check(find("display").?, "HDMI-A-1") == null);
    try testing.expect(check(find("display").?, "HDMI A") != null);
    try testing.expect(check(find("login-program").?, "/bin/login") == null);
    try testing.expect(check(find("login-program").?, "login") != null);
    try testing.expect(check(find("fallback").?, "/sbin/agetty --noclear tty%N linux") == null);
    try testing.expect(check(find("fallback").?, "agetty tty%N") != null);
    try testing.expect(check(find("fallback").?, "") != null);
    try testing.expect(check(find("colors").?, "campbell") == null);
    try testing.expect(check(find("colors").?, "x") != null);
    try testing.expect(check(find("cursor-blink").?, "true") == null);
}

test "fallback expands the vt number" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try expandFallback(&aw.writer, "/sbin/agetty --noclear tty%N linux", 3);
    try testing.expectEqualStrings("/sbin/agetty --noclear tty3 linux", aw.written());
}

test "the shared terminal settings are read as DKTerm reads them" {
    var etc = try ini.Document.parse(testing.allocator, "[console]\ncolor-scheme = \"one-half-dark\"\ncursor-style = \"underline\"\nscrollback-lines = 321\nosc52 = true\n");
    defer etc.deinit();
    const s = Settings.resolve(.{ .etc = &etc }, 1);
    try testing.expectEqualStrings("one-half-dark", s.color_scheme);
    try testing.expectEqual(termcore.options.CursorStyle.underline, s.cursor);
    try testing.expectEqual(@as(u32, 321), s.scrollback_lines);
    try testing.expect(s.osc52);
    const d = Settings.resolve(.{}, 1);
    try testing.expectEqual(termcore.options.CursorStyle.block, d.cursor);
    try testing.expect(!d.osc52);
}

test "the older name colors still works, and color-scheme beats it" {
    var old = try ini.Document.parse(testing.allocator, "[console]\ncolors = \"solarized-dark\"\n");
    defer old.deinit();
    try testing.expectEqualStrings("solarized-dark", Settings.resolve(.{ .etc = &old }, 1).color_scheme);
    // The newer name wins within a group, but a VT's group beats [console].
    var both = try ini.Document.parse(testing.allocator, "[console]\ncolors = \"solarized-dark\"\ncolor-scheme = \"one-half-dark\"\n[vt.2]\ncolors = \"solarized-light\"\n");
    defer both.deinit();
    try testing.expectEqualStrings("one-half-dark", Settings.resolve(.{ .etc = &both }, 1).color_scheme);
    try testing.expectEqualStrings("solarized-light", Settings.resolve(.{ .etc = &both }, 2).color_scheme);
    try testing.expectEqualStrings("color-scheme", find("colors").?.name);
}
