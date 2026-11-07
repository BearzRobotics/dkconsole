//! The console's configuration document, on toml-zig.
//!
//! The console's settings are all text on the command line (`config set KEY
//! VALUE`), so this keeps the small interface the rest of the code was written
//! for: look a value up as text, set one from text, remove one. Underneath,
//! the file is TOML and a value keeps its TOML type: `true` and `false` are
//! booleans, whole numbers are integers, everything else is a string.
//!
//! Groups: `console` is the table `[console]`; `vt:2` is the table `[vt.2]`.
//! Unknown keys and tables are kept when the file is written back. Comments
//! are not (toml-zig does not preserve them; see its SPEC), which is why the
//! documented defaults live in `config.example.toml`, not in /etc.

const std = @import("std");
const toml = @import("toml");
const Allocator = std.mem.Allocator;

pub const Document = struct {
    gpa: Allocator,
    /// Null until something is set: reading an empty document needs no allocation.
    doc: ?toml.Document = null,
    /// Text made for non-string values on `get`.
    scratch: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) Document {
        return .{ .gpa = gpa, .scratch = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Document) void {
        if (self.doc) |*d| d.deinit();
        self.scratch.deinit();
        self.* = undefined;
    }

    /// Parses `text`. A document that is not valid TOML is an error, so the
    /// caller keeps what it had (a full invalid file is never half applied).
    pub fn parse(gpa: Allocator, text: []const u8) !Document {
        var self = init(gpa);
        errdefer self.deinit();
        self.doc = try toml.Document.parse(gpa, text, .{}, null);
        return self;
    }

    /// The TOML text of the document; the caller frees it with `allocator`.
    pub fn toOwnedString(self: *const Document, allocator: Allocator) ![]u8 {
        if (self.doc) |*d| return d.toOwnedString(allocator) catch error.OutOfMemory;
        return allocator.dupe(u8, "");
    }

    /// The table path of a group name: `console` or `vt:N`.
    fn path(group: []const u8, buf: *[2][]const u8) []const []const u8 {
        if (std.mem.startsWith(u8, group, "vt:")) {
            buf[0] = "vt";
            buf[1] = group[3..];
            return buf[0..2];
        }
        buf[0] = group;
        return buf[0..1];
    }

    fn table(self: *const Document, group: []const u8) ?*const toml.Table {
        const d = self.doc orelse return null;
        var buf: [2][]const u8 = undefined;
        var cur: *const toml.Table = d.root;
        for (path(group, &buf)) |seg| cur = cur.getTable(seg) orelse return null;
        return cur;
    }

    pub fn hasGroup(self: *const Document, group: []const u8) bool {
        return self.table(group) != null;
    }

    /// The value as text, or null when there is none. A string is returned as
    /// it is; an integer, boolean or float as its TOML text. The slice is valid
    /// until the document changes.
    pub fn get(self: *const Document, group: []const u8, key: []const u8) ?[]const u8 {
        const t = self.table(group) orelse return null;
        const v = t.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            .integer => |i| self.format("{d}", .{i}),
            .boolean => |b| if (b) "true" else "false",
            .float => |f| self.format("{d}", .{f}),
            else => null,
        };
    }

    fn format(self: *const Document, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        // `scratch` is an implementation detail of reading, not document state.
        const scratch: *std.heap.ArenaAllocator = @constCast(&self.scratch);
        return std.fmt.allocPrint(scratch.allocator(), fmt, args) catch null;
    }

    /// Sets `group.key` from text; returns false when the value was already
    /// that (nothing changed, so nothing needs writing).
    pub fn set(self: *Document, group: []const u8, key: []const u8, value: []const u8) !bool {
        if (self.get(group, key)) |old| if (std.mem.eql(u8, old, value)) return false;
        if (self.doc == null) self.doc = try toml.Document.init(self.gpa);
        const d = &self.doc.?;
        var buf: [2][]const u8 = undefined;
        const base = path(group, &buf);
        var full: [3][]const u8 = undefined;
        @memcpy(full[0..base.len], base);
        full[base.len] = key;
        const v: toml.Value = if (parseBool(value)) |b|
            .{ .boolean = b }
        else if (std.fmt.parseInt(i64, value, 10)) |n|
            .{ .integer = n }
        else |_|
            .{ .string = try d.dupe(value) };
        d.set(full[0 .. base.len + 1], v) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // A key where a table belongs (or the reverse): the file is not one we wrote.
            error.NotATable => return error.InvalidDocument,
        };
        // `vt` only holds the per-VT tables: write `[vt.2]`, not an empty `[vt]` as well.
        if (base.len == 2) if (d.root.getTable(base[0])) |parent| {
            parent.kind = .implicit;
        };
        return true;
    }

    /// Removes `group.key`; false when it was not there.
    pub fn remove(self: *Document, group: []const u8, key: []const u8) bool {
        const d = self.doc orelse return false;
        var buf: [2][]const u8 = undefined;
        var cur: *toml.Table = d.root;
        for (path(group, &buf)) |seg| cur = cur.getTable(seg) orelse return false;
        return cur.remove(key);
    }
};

/// `true` or `false` (any case); null for anything else.
pub fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

const testing = std.testing;

test "groups, types and text round trip" {
    var d = try Document.parse(testing.allocator,
        \\[console]
        \\font-size = 24
        \\cursor-blink = true
        \\colors = "campbell"
        \\
        \\[vt.2]
        \\font-size = 32
        \\
    );
    defer d.deinit();
    try testing.expectEqualStrings("24", d.get("console", "font-size").?);
    try testing.expectEqualStrings("true", d.get("console", "cursor-blink").?);
    try testing.expectEqualStrings("campbell", d.get("console", "colors").?);
    try testing.expectEqualStrings("32", d.get("vt:2", "font-size").?);
    try testing.expect(d.get("vt:3", "font-size") == null);
    try testing.expect(d.hasGroup("vt:2"));
    try testing.expect(!d.hasGroup("vt:9"));
}

test "set keeps types, reports no change, and unknown keys survive" {
    var d = try Document.parse(testing.allocator, "[console]\nmystery = 5\n");
    defer d.deinit();
    try testing.expect(try d.set("console", "scale", "2"));
    try testing.expect(!(try d.set("console", "scale", "2")));
    try testing.expect(try d.set("console", "cursor-blink", "false"));
    try testing.expect(try d.set("console", "font", "/usr/share/fonts/x.ttf"));
    try testing.expect(try d.set("vt:1", "font-size", "32"));
    const text = try d.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    // Typed in the file, and the key this code does not know is still there.
    try testing.expect(std.mem.indexOf(u8, text, "scale = 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cursor-blink = false") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mystery = 5") != null);
    var back = try Document.parse(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqualStrings("32", back.get("vt:1", "font-size").?);
}

test "remove, an empty document, and invalid TOML" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.get("console", "x") == null);
    try testing.expect(!d.remove("console", "x"));
    try testing.expect(try d.set("console", "x", "1"));
    try testing.expect(d.remove("console", "x"));
    try testing.expect(d.get("console", "x") == null);
    try testing.expectError(error.Syntax, Document.parse(testing.allocator, "[console\nfont = \n"));
}
