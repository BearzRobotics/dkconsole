//! Input straight from the kernel's evdev nodes (SPEC.md 5.11, *Input*): no
//! libinput, libevdev, mtdev or udev. Devices are classified by what they
//! can report, and inotify on /dev/input picks up devices plugged in later
//! (devtmpfs creates the nodes itself). Key repeat comes from the kernel as
//! `value == 2` events.

const std = @import("std");
const sys = @import("sys.zig");

const log = std.log.scoped(.evdev);

const EV_SYN = 0x00;
const EV_KEY = 0x01;
const EV_REL = 0x02;
const EV_ABS = 0x03;
const SYN_REPORT = 0;
const SYN_DROPPED = 3;
const KEY_A = 30;
const KEY_KP1 = 79;
const KEY_KPENTER = 96;
const BTN_TOOL_FINGER = 0x145;
const BTN_TOOL_QUINTTAP = 0x148;
const BTN_TOOL_DOUBLETAP = 0x14d;
const BTN_TOOL_QUADTAP = 0x14f;
const INPUT_PROP_DIRECT = 1;
/// How far the pointer moves when a finger crosses a whole touchpad.
const touchpad_travel = 1200;
const BTN_MOUSE = 0x110;
const BTN_TOUCH = 0x14a;
const REL_X = 0;
const REL_Y = 1;
const REL_HWHEEL = 6;
const REL_WHEEL = 8;
const ABS_X = 0;
const ABS_Y = 1;
const KEY_MAX = 0x2ff;

pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_MIDDLE = 0x112;

const InputEvent = extern struct { sec: c_long, usec: c_long, type: u16, code: u16, value: i32 };
const AbsInfo = extern struct { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 };

fn eviocgbit(ev: u32, len: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, len) << 16) | (@as(c_ulong, 'E') << 8) | (0x20 + ev);
}
/// EVIOCGNAME(len): the device's name.
fn eviocgname(len: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, len) << 16) | (@as(c_ulong, 'E') << 8) | 0x06;
}
fn eviocgabs(axis: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, @sizeOf(AbsInfo)) << 16) | (@as(c_ulong, 'E') << 8) | (0x40 + axis);
}

/// EVIOCGPROP(len) and EVIOCGKEY(len): properties, and the keys now down.
fn eviocgprop(len: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, len) << 16) | (@as(c_ulong, 'E') << 8) | 0x09;
}
fn eviocgkey(len: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, len) << 16) | (@as(c_ulong, 'E') << 8) | 0x18;
}

extern fn inotify_init1(flags: c_int) c_int;
extern fn inotify_add_watch(fd: c_int, path: [*:0]const u8, mask: u32) c_int;

pub const Kind = enum { keyboard, mouse, absolute, touchpad };

const KeySet = std.bit_set.Static(KEY_MAX + 1);

pub const Device = struct {
    fd: c_int,
    kind: Kind,
    /// Absolute pointers: the axis ranges.
    abs_x: AbsInfo = std.mem.zeroes(AbsInfo),
    abs_y: AbsInfo = std.mem.zeroes(AbsInfo),
    /// Absolute pointers: last position seen, in device units.
    last_x: i32 = 0,
    last_y: i32 = 0,
    /// Index into the node list, so a removed device can be matched.
    number: u32,
    /// The keys and buttons reported down and not yet up.
    down: KeySet = .empty,
    /// Events were lost; what follows up to the next report is incomplete.
    dropped: bool = false,
    /// Touchpads: the finger's last position, while it stays on the pad, and
    /// motion not yet a whole pixel (in 1/axis-span units).
    touch_from: ?[2]i32 = null,
    remainder: [2]i64 = .{ 0, 0 },
    touching: bool = false,
};

/// The motion read in one batch of events, sent as one.
const Batch = struct {
    dx: i32 = 0,
    dy: i32 = 0,
    wheel: i32 = 0,
    moved_abs: bool = false,
};

/// What the console cares about, already reduced.
pub const Event = union(enum) {
    key: struct { code: u16, value: i32 },
    /// Relative pointer motion in device units.
    motion: struct { dx: i32, dy: i32 },
    /// Absolute pointer position as a fraction of the screen, 0..65535.
    position: struct { x: u16, y: u16 },
    button: struct { code: u16, pressed: bool },
    /// Positive is away from the user (up). One notch is 1.
    wheel: i32,
};

fn bitSet(bits: []const u8, n: usize) bool {
    return n / 8 < bits.len and bits[n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// Decide what a device is from its capability bits, or null if it is none of
/// the kinds the console uses. Split from the ioctls so it can be tested.
pub fn classify(ev_bits: []const u8, key_bits: []const u8, rel_bits: []const u8, abs_bits: []const u8) ?Kind {
    const has_keys = bitSet(ev_bits, EV_KEY);
    if (has_keys and bitSet(key_bits, KEY_A)) return .keyboard;
    // A keypad on its own.
    if (has_keys and bitSet(key_bits, KEY_KP1) and bitSet(key_bits, KEY_KPENTER)) return .keyboard;
    if (bitSet(ev_bits, EV_REL) and bitSet(rel_bits, REL_X) and bitSet(rel_bits, REL_Y) and bitSet(key_bits, BTN_MOUSE)) return .mouse;
    // Tablets and touchpads (single-touch axes) report absolute X and Y.
    if (bitSet(ev_bits, EV_ABS) and bitSet(abs_bits, ABS_X) and bitSet(abs_bits, ABS_Y) and
        (bitSet(key_bits, BTN_MOUSE) or bitSet(key_bits, BTN_TOUCH))) return .absolute;
    return null;
}

pub const Input = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayList(Device) = .empty,
    watch_fd: c_int = -1,

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Input) void {
        self.closeAll();
        self.devices.deinit(self.allocator);
    }

    /// Open every usable device, and start watching for new ones.
    pub fn open(self: *Input) void {
        if (self.watch_fd < 0) {
            self.watch_fd = inotify_init1(sys.O_CLOEXEC | sys.O_NONBLOCK);
            if (self.watch_fd >= 0) _ = inotify_add_watch(self.watch_fd, "/dev/input", 0x100); // IN_CREATE
        }
        var n: u32 = 0;
        while (n < 64) : (n += 1) self.tryOpen(n);
    }

    /// Close the devices (and the watch): done when the VT is released, so a
    /// background console reads nothing and wakes for nothing.
    pub fn closeAll(self: *Input) void {
        for (self.devices.items) |d| _ = sys.close(d.fd);
        self.devices.clearRetainingCapacity();
        if (self.watch_fd >= 0) {
            _ = sys.close(self.watch_fd);
            self.watch_fd = -1;
        }
    }

    fn isOpen(self: *const Input, number: u32) bool {
        for (self.devices.items) |d| if (d.number == number) return true;
        return false;
    }

    fn tryOpen(self: *Input, number: u32) void {
        if (self.isOpen(number)) return;
        var pb: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "/dev/input/event{d}", .{number}, 0) catch return;
        const fd = sys.open(path.ptr, sys.O_RDONLY | sys.O_NONBLOCK | sys.O_CLOEXEC);
        if (fd < 0) return;
        var ev_bits: [4]u8 = @splat(0);
        var key_bits: [(KEY_MAX + 8) / 8]u8 = @splat(0);
        var rel_bits: [4]u8 = @splat(0);
        var abs_bits: [8]u8 = @splat(0);
        _ = sys.ioctl(fd, eviocgbit(0, ev_bits.len), &ev_bits);
        _ = sys.ioctl(fd, eviocgbit(EV_KEY, key_bits.len), &key_bits);
        _ = sys.ioctl(fd, eviocgbit(EV_REL, rel_bits.len), &rel_bits);
        _ = sys.ioctl(fd, eviocgbit(EV_ABS, abs_bits.len), &abs_bits);
        const kind = classify(&ev_bits, &key_bits, &rel_bits, &abs_bits) orelse {
            log.debug("event{d}: not a keyboard or pointer, skipped", .{number});
            _ = sys.close(fd);
            return;
        };
        var dev: Device = .{ .fd = fd, .kind = kind, .number = number };
        if (kind == .absolute) {
            // A pad moves the pointer; a screen or tablet places it.
            var props: [4]u8 = @splat(0);
            _ = sys.ioctl(fd, eviocgprop(props.len), &props);
            if (bitSet(&key_bits, BTN_TOOL_FINGER) and !bitSet(&props, INPUT_PROP_DIRECT)) dev.kind = .touchpad;
            _ = sys.ioctl(fd, eviocgabs(ABS_X), &dev.abs_x);
            _ = sys.ioctl(fd, eviocgabs(ABS_Y), &dev.abs_y);
            if (dev.abs_x.maximum <= dev.abs_x.minimum or dev.abs_y.maximum <= dev.abs_y.minimum) {
                log.warn("event{d}: absolute pointer with an empty axis range, skipped", .{number});
                _ = sys.close(fd);
                return;
            }
        }
        self.devices.append(self.allocator, dev) catch {
            _ = sys.close(fd);
            return;
        };
        var name: [64]u8 = @splat(0);
        _ = sys.ioctl(fd, eviocgname(name.len), &name);
        log.info("input: event{d} {s} ({s})", .{ number, @tagName(kind), std.mem.sliceTo(&name, 0) });
    }

    /// Fill `fds` with the descriptors to poll (the hotplug watch first, then
    /// the devices) and return how many were used.
    pub fn pollFds(self: *const Input, fds: []PollFd) usize {
        var n: usize = 0;
        if (self.watch_fd >= 0 and n < fds.len) {
            fds[n] = .{ .fd = self.watch_fd, .events = POLLIN, .revents = 0 };
            n += 1;
        }
        for (self.devices.items) |d| {
            if (n >= fds.len) break;
            fds[n] = .{ .fd = d.fd, .events = POLLIN, .revents = 0 };
            n += 1;
        }
        return n;
    }

    /// Read what is waiting on `fd` (one of the descriptors from `pollFds`) and
    /// append the events. A device that went away is closed and dropped.
    pub fn service(self: *Input, fd: c_int, out: *std.ArrayList(Event)) void {
        if (fd == self.watch_fd) {
            self.drainWatch();
            return;
        }
        var index: ?usize = null;
        for (self.devices.items, 0..) |d, i| if (d.fd == fd) {
            index = i;
            break;
        };
        const i = index orelse return;
        const dev = &self.devices.items[i];

        var buf: [32]InputEvent = undefined;
        var batch: Batch = .{};
        while (true) {
            const n = sys.read(fd, @ptrCast(&buf), @sizeOf(@TypeOf(buf)));
            if (n < 0) {
                if (sys.errno() == sys.EINTR) continue;
                if (sys.errno() == sys.EAGAIN) break;
                // The device is gone (ENODEV) or unreadable. It will never
                // say that its keys came up.
                self.releaseKeys(dev, null, out);
                _ = sys.close(fd);
                _ = self.devices.swapRemove(i);
                return;
            }
            if (n == 0) break;
            const count = @as(usize, @intCast(n)) / @sizeOf(InputEvent);
            for (buf[0..count]) |e| self.feed(dev, e, &batch, out);
            if (count < buf.len) break;
        }
        self.finishBatch(dev, batch, out);
    }

    /// Takes one event of `dev`.
    fn feed(self: *Input, dev: *Device, e: InputEvent, batch: *Batch, out: *std.ArrayList(Event)) void {
        if (e.type == EV_SYN and e.code == SYN_DROPPED) {
            dev.dropped = true;
            return;
        }
        if (dev.dropped) {
            if (e.type == EV_SYN and e.code == SYN_REPORT) {
                dev.dropped = false;
                // A release among the lost events would leave a key stuck.
                var now: [(KEY_MAX + 8) / 8]u8 = @splat(0);
                _ = sys.ioctl(dev.fd, eviocgkey(now.len), &now);
                self.releaseKeys(dev, &now, out);
                dev.touch_from = null;
            }
            return;
        }
        switch (e.type) {
            EV_KEY => {
                if (e.code <= KEY_MAX) dev.down.setValue(e.code, e.value != 0);
                if (dev.kind == .touchpad) {
                    // A finger touching is not a click. When the number of
                    // fingers changes, the reported position jumps.
                    if (e.code == BTN_TOUCH) dev.touching = e.value != 0;
                    if (e.code == BTN_TOUCH or (e.code >= BTN_TOOL_FINGER and e.code <= BTN_TOOL_QUINTTAP) or
                        (e.code >= BTN_TOOL_DOUBLETAP and e.code <= BTN_TOOL_QUADTAP))
                    {
                        dev.touch_from = null;
                    }
                }
                if (dev.kind == .keyboard and e.code < 0x100) {
                    out.append(self.allocator, .{ .key = .{ .code = e.code, .value = e.value } }) catch {};
                } else if (buttonFor(dev.kind, e.code)) |code| {
                    if (e.value != 2) out.append(self.allocator, .{ .button = .{ .code = code, .pressed = e.value != 0 } }) catch {};
                }
            },
            EV_REL => switch (e.code) {
                REL_X => batch.dx +|= e.value,
                REL_Y => batch.dy +|= e.value,
                REL_WHEEL => batch.wheel +|= e.value,
                else => {},
            },
            EV_ABS => if ((dev.kind == .absolute or dev.kind == .touchpad) and (e.code == ABS_X or e.code == ABS_Y)) {
                if (e.code == ABS_X) dev.last_x = e.value else dev.last_y = e.value;
                batch.moved_abs = true;
            },
            EV_SYN => if (e.code == SYN_REPORT and dev.kind == .touchpad) touchMotion(dev, batch),
            else => {},
        }
    }

    /// The button a key code presses on this kind of device, if any.
    fn buttonFor(kind: Kind, code: u16) ?u16 {
        if (code >= BTN_MOUSE and code <= BTN_MIDDLE) return code;
        // On a screen or tablet, a touch is the click.
        if (code == BTN_TOUCH and kind != .touchpad) return BTN_LEFT;
        return null;
    }

    /// Reports as released the keys of `dev` that are down, except those
    /// `still` has.
    fn releaseKeys(self: *Input, dev: *Device, still: ?[]const u8, out: *std.ArrayList(Event)) void {
        var code: u16 = 0;
        while (code <= KEY_MAX) : (code += 1) {
            if (!dev.down.isSet(code)) continue;
            if (still) |bits| if (bitSet(bits, code)) continue;
            dev.down.unset(code);
            if (dev.kind == .keyboard and code < 0x100) {
                out.append(self.allocator, .{ .key = .{ .code = code, .value = 0 } }) catch {};
            } else if (buttonFor(dev.kind, code)) |button| {
                out.append(self.allocator, .{ .button = .{ .code = button, .pressed = false } }) catch {};
            }
        }
    }

    /// A touchpad reports where the finger is; the pointer moves as far as
    /// the finger did since the last report.
    fn touchMotion(dev: *Device, batch: *Batch) void {
        if (!dev.touching) return;
        const at = [2]i32{ dev.last_x, dev.last_y };
        if (dev.touch_from) |from| {
            // The same scale on both axes keeps diagonals straight.
            const span: i64 = @max(1, @as(i64, dev.abs_x.maximum) - dev.abs_x.minimum);
            var moved: [2]i32 = undefined;
            for (0..2) |axis| {
                const total = (@as(i64, at[axis]) - from[axis]) * touchpad_travel + dev.remainder[axis];
                moved[axis] = std.math.lossyCast(i32, @divTrunc(total, span));
                dev.remainder[axis] = @rem(total, span);
            }
            batch.dx +|= moved[0];
            batch.dy +|= moved[1];
        } else dev.remainder = .{ 0, 0 };
        dev.touch_from = at;
    }

    fn finishBatch(self: *Input, dev: *const Device, batch: Batch, out: *std.ArrayList(Event)) void {
        if (batch.dx != 0 or batch.dy != 0) out.append(self.allocator, .{ .motion = .{ .dx = batch.dx, .dy = batch.dy } }) catch {};
        if (batch.wheel != 0) out.append(self.allocator, .{ .wheel = batch.wheel }) catch {};
        if (batch.moved_abs and dev.kind == .absolute) {
            out.append(self.allocator, .{ .position = .{
                .x = scale(dev.last_x, dev.abs_x),
                .y = scale(dev.last_y, dev.abs_y),
            } }) catch {};
        }
    }

    fn drainWatch(self: *Input) void {
        var buf: [1024]u8 align(4) = undefined;
        while (true) {
            const n = sys.read(self.watch_fd, &buf, buf.len);
            if (n <= 0) break;
        }
        // devtmpfs may still be setting the node up; scanning again is cheap
        // and ignores devices that are already open.
        var n: u32 = 0;
        while (n < 64) : (n += 1) self.tryOpen(n);
    }
};

fn scale(v: i32, info: AbsInfo) u16 {
    const span: i64 = @as(i64, info.maximum) - info.minimum;
    if (span <= 0) return 0;
    const p = std.math.clamp(@as(i64, v) - info.minimum, 0, span);
    return @intCast(@divTrunc(p * 65535, span));
}

pub const POLLIN: c_short = 1;
pub const POLLOUT: c_short = 4;
pub const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };

const testing = std.testing;

fn bitsOf(comptime n: usize, set: []const usize) [n]u8 {
    var b: [n]u8 = @splat(0);
    for (set) |i| b[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    return b;
}

test "classify keyboards, mice and tablets" {
    const ev_kbd = bitsOf(4, &.{ EV_SYN, EV_KEY });
    const keys_kbd = bitsOf(96, &.{ KEY_A, 1 });
    try testing.expectEqual(Kind.keyboard, classify(&ev_kbd, &keys_kbd, &.{}, &.{}).?);

    const ev_mouse = bitsOf(4, &.{ EV_KEY, EV_REL });
    const keys_mouse = bitsOf(96, &.{BTN_MOUSE});
    const rel = bitsOf(4, &.{ REL_X, REL_Y, REL_WHEEL });
    try testing.expectEqual(Kind.mouse, classify(&ev_mouse, &keys_mouse, &rel, &.{}).?);

    const ev_tab = bitsOf(4, &.{ EV_KEY, EV_ABS });
    const keys_tab = bitsOf(96, &.{BTN_TOUCH});
    const abs = bitsOf(8, &.{ ABS_X, ABS_Y });
    try testing.expectEqual(Kind.absolute, classify(&ev_tab, &keys_tab, &.{}, &abs).?);

    // A lid switch, or a power button with no letter keys.
    const ev_btn = bitsOf(4, &.{EV_KEY});
    const keys_btn = bitsOf(96, &.{116});
    try testing.expect(classify(&ev_btn, &keys_btn, &.{}, &.{}) == null);
}

test "absolute scaling" {
    const info: AbsInfo = .{ .value = 0, .minimum = 100, .maximum = 1100, .fuzz = 0, .flat = 0, .resolution = 0 };
    try testing.expectEqual(@as(u16, 0), scale(100, info));
    try testing.expectEqual(@as(u16, 65535), scale(1100, info));
    try testing.expectEqual(@as(u16, 32767), scale(600, info));
    try testing.expectEqual(@as(u16, 0), scale(-5, info));
}

test "struct sizes" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
    // EVIOCGBIT(EV_KEY, 96) and EVIOCGABS(ABS_X).
    try testing.expectEqual(@as(c_ulong, 0x80604521), eviocgbit(EV_KEY, 96));
    try testing.expectEqual(@as(c_ulong, 0x80184540), eviocgabs(ABS_X));
}

fn testFeed(input: *Input, dev: *Device, events: []const struct { u16, u16, i32 }, out: *std.ArrayList(Event)) void {
    var batch: Batch = .{};
    for (events) |e| input.feed(dev, .{ .sec = 0, .usec = 0, .type = e[0], .code = e[1], .value = e[2] }, &batch, out);
    input.finishBatch(dev, batch, out);
}

test "keys held by a device that goes away or loses events are released" {
    var input = Input.init(std.testing.allocator);
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(std.testing.allocator);
    // fd -1: asking which keys are down fails, as if none were.
    var dev: Device = .{ .fd = -1, .kind = .keyboard, .number = 0 };
    testFeed(&input, &dev, &.{ .{ EV_KEY, 42, 1 }, .{ EV_KEY, 29, 1 }, .{ EV_KEY, 29, 0 } }, &out);
    out.clearRetainingCapacity();
    testFeed(&input, &dev, &.{ .{ EV_SYN, SYN_DROPPED, 0 }, .{ EV_KEY, 30, 1 }, .{ EV_SYN, SYN_REPORT, 0 } }, &out);
    // Shift (42) comes up; the half-seen 'a' is ignored.
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u16, 42), out.items[0].key.code);
    try std.testing.expectEqual(@as(i32, 0), out.items[0].key.value);

    testFeed(&input, &dev, &.{.{ EV_KEY, 56, 1 }}, &out);
    out.clearRetainingCapacity();
    input.releaseKeys(&dev, null, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u16, 56), out.items[0].key.code);
}

test "a touchpad moves the pointer and a touch is not a click" {
    var input = Input.init(std.testing.allocator);
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(std.testing.allocator);
    var pad: Device = .{ .fd = -1, .kind = .touchpad, .number = 0 };
    pad.abs_x.maximum = touchpad_travel;
    pad.abs_y.maximum = 800;
    const report = .{ EV_SYN, SYN_REPORT, 0 };
    testFeed(&input, &pad, &.{ .{ EV_KEY, BTN_TOUCH, 1 }, .{ EV_ABS, ABS_X, 500 }, .{ EV_ABS, ABS_Y, 400 }, report }, &out);
    testFeed(&input, &pad, &.{ .{ EV_ABS, ABS_X, 510 }, .{ EV_ABS, ABS_Y, 395 }, report }, &out);
    // Lifting and touching elsewhere moves nothing.
    testFeed(&input, &pad, &.{ .{ EV_KEY, BTN_TOUCH, 0 }, report, .{ EV_KEY, BTN_TOUCH, 1 }, .{ EV_ABS, ABS_X, 100 }, report }, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(i32, 10), out.items[0].motion.dx);
    try std.testing.expectEqual(@as(i32, -5), out.items[0].motion.dy);
    // The pad's button still clicks.
    out.clearRetainingCapacity();
    testFeed(&input, &pad, &.{.{ EV_KEY, BTN_LEFT, 1 }}, &out);
    try std.testing.expect(out.items[0].button.pressed);
}

test "a keypad on its own is a keyboard" {
    var key_bits: [32]u8 = @splat(0);
    for ([_]usize{ KEY_KP1, KEY_KPENTER }) |k| key_bits[k / 8] |= @as(u8, 1) << @intCast(k % 8);
    try std.testing.expectEqual(@as(?Kind, .keyboard), classify(&.{1 << EV_KEY}, &key_bits, &.{}, &.{}));
}
