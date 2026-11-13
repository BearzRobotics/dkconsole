//! `/etc/issue` with agetty's backslash escapes (SPEC.md 5.11, *Process
//! model*). The console prints this before it starts `login`.

const std = @import("std");
const builtin = @import("builtin");

/// What the escapes stand for. `System.read` fills it from the running system;
/// tests build it by hand.
pub const System = struct {
    sysname: []const u8 = "Linux",
    nodename: []const u8 = "localhost",
    release: []const u8 = "",
    version: []const u8 = "",
    machine: []const u8 = "",
    /// The line, `tty1` style, without `/dev/`.
    line: []const u8 = "tty1",
    /// `\d` and `\t`, already formatted by the caller.
    date: []const u8 = "",
    time: []const u8 = "",
    users: u32 = 0,
    /// NIS domain name, for `\o` and `\O`.
    domain: []const u8 = "",
    /// The text of /etc/os-release, for `\S` and `\S{VAR}`.
    os_release: []const u8 = "",
};

/// The value of `name` in os-release text (`NAME=value`, optionally quoted),
/// or null.
pub fn osReleaseValue(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len <= name.len or line[name.len] != '=' or !std.mem.startsWith(u8, line, name)) continue;
        var v = line[name.len + 1 ..];
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
        return v;
    }
    return null;
}

extern fn time(t: ?*i64) i64;
extern fn localtime_r(t: *const i64, tm: *anyopaque) ?*anyopaque;
extern fn strftime(buf: [*]u8, max: usize, fmt: [*:0]const u8, tm: *const anyopaque) usize;

/// Local date and time as agetty prints them (`Fri Nov 13 2026`, `14:05:09`).
pub const Clock = struct {
    date_buf: [48]u8 = undefined,
    time_buf: [16]u8 = undefined,
    date: []const u8 = "",
    time: []const u8 = "",

    pub fn now(self: *Clock) void {
        var t: i64 = time(null);
        var tm: [64]u8 align(8) = undefined; // glibc's struct tm is 56 bytes
        if (localtime_r(&t, &tm) == null) return;
        self.date = self.date_buf[0..strftime(&self.date_buf, self.date_buf.len, "%a %b %e %Y", &tm)];
        self.time = self.time_buf[0..strftime(&self.time_buf, self.time_buf.len, "%H:%M:%S", &tm)];
    }
};

/// Logged-in users: USER_PROCESS records in utmp. Every Linux ABI uses
/// 384-byte records with the type in the first two bytes.
pub fn countUsers(utmp: []const u8) u32 {
    const rec = 384;
    var n: u32 = 0;
    var i: usize = 0;
    while (i + rec <= utmp.len) : (i += rec) {
        if (std.mem.readInt(u16, utmp[i..][0..2], builtin.cpu.arch.endian()) == 7) n += 1;
    }
    return n;
}

const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};
extern fn uname(buf: *Utsname) c_int;

/// Backing storage for the slices in a `System` made by `read`.
pub const Uts = struct {
    raw: Utsname = undefined,

    pub fn system(self: *Uts, line: []const u8) System {
        if (uname(&self.raw) != 0) return .{ .line = line };
        const s = struct {
            fn z(a: *const [65]u8) []const u8 {
                return std.mem.sliceTo(a, 0);
            }
        }.z;
        return .{
            .sysname = s(&self.raw.sysname),
            .nodename = s(&self.raw.nodename),
            .release = s(&self.raw.release),
            .version = s(&self.raw.version),
            .machine = s(&self.raw.machine),
            .domain = s(&self.raw.domainname),
            .line = line,
        };
    }
};

/// Expand `text` into `out`. Unknown escapes are copied as written, as
/// agetty does. Newlines become CR LF because the console's pty is in raw
/// output mode until `login` takes over.
pub fn expand(out: *std.Io.Writer, text: []const u8, sys: System) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\n') {
            try out.writeAll("\r\n");
            continue;
        }
        if (c != '\\' or i + 1 >= text.len) {
            try out.writeByte(c);
            continue;
        }
        i += 1;
        switch (text[i]) {
            'n' => try out.writeAll(sys.nodename),
            'l' => try out.writeAll(sys.line),
            's' => try out.writeAll(sys.sysname),
            'r' => try out.writeAll(sys.release),
            'm' => try out.writeAll(sys.machine),
            'v' => try out.writeAll(sys.version),
            'd' => try out.writeAll(sys.date),
            't' => try out.writeAll(sys.time),
            'e' => try out.writeByte(0x1b),
            'o', 'O' => try out.writeAll(sys.domain),
            'S' => {
                // `\S` is the distribution's pretty name, `\S{VAR}` any os-release field.
                var name: []const u8 = "PRETTY_NAME";
                if (i + 1 < text.len and text[i + 1] == '{') {
                    if (std.mem.indexOfScalarPos(u8, text, i + 2, '}')) |end| {
                        name = text[i + 2 .. end];
                        i = end;
                    }
                }
                try out.writeAll(osReleaseValue(sys.os_release, name) orelse if (std.mem.eql(u8, name, "PRETTY_NAME")) sys.sysname else "");
            },
            'u' => try out.print("{d}", .{sys.users}),
            'U' => try out.print("{d} user{s}", .{ sys.users, if (sys.users == 1) "" else "s" }),
            '\\' => try out.writeByte('\\'),
            else => |other| {
                try out.writeByte('\\');
                try out.writeByte(other);
            },
        }
    }
}

fn run(text: []const u8, sys: System) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    try expand(&aw.writer, text, sys);
    return aw.toOwnedSlice();
}

test "escapes" {
    const sys: System = .{ .nodename = "dk", .release = "6.1", .machine = "x86_64", .line = "tty2", .users = 1 };
    const out = try run("Welcome to \\n (\\s \\r \\m) on \\l\nbye \\q \\\\ \\U", sys);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Welcome to dk (Linux 6.1 x86_64) on tty2\r\nbye \\q \\ 1 user", out);
}

test "newlines get a carriage return and a lone trailing backslash is kept" {
    const out = try run("a\nb\\", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\r\nb\\", out);
}

test "dates, domain and os-release" {
    const sys: System = .{
        .date = "Fri Nov 13 2026",
        .time = "14:05:09",
        .domain = "example.org",
        .sysname = "Linux",
        .os_release = "NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 26.04.1 LTS\"\nID=ubuntu\nVERSION_ID='26.04'\n",
    };
    const out = try run("\\d \\t \\o|\\S|\\S{VERSION_ID}|\\S{NOPE}|\\S{ID", sys);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Fri Nov 13 2026 14:05:09 example.org|Ubuntu 26.04.1 LTS|26.04||Ubuntu 26.04.1 LTS{ID", out);
}

test "os-release falls back to the system name; escapes and \\e pass through" {
    const out = try run("\\S \\e[1m", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Linux \x1b[1m", out);
}

test "user counting" {
    var buf: [384 * 3]u8 = @splat(0);
    std.mem.writeInt(u16, buf[0..2], 7, builtin.cpu.arch.endian());
    std.mem.writeInt(u16, buf[384..][0..2], 8, builtin.cpu.arch.endian());
    std.mem.writeInt(u16, buf[768..][0..2], 7, builtin.cpu.arch.endian());
    try std.testing.expectEqual(@as(u32, 2), countUsers(&buf));
    try std.testing.expectEqual(@as(u32, 0), countUsers(buf[0..100]));
}
