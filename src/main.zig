const std = @import("std");
const Allocator = std.mem.Allocator;
const dp = std.debug.print;
const os = std.os;
const posix = std.posix;

// TODO: make this signature better
const Op = struct {
    name: []const u8,
    func: fn (rest: []const u8, writer: anytype, reader: anytype) void,
};
const cd = Op{
    .name = "cd",
    .func = cdfunc,
};

fn parse(al: Allocator, s: []const u8) ![][]u8 {
    var parts = std.ArrayList([]u8).init(al);
    const si = std.mem.splitScalar(u8, s, ' ');
    while (si.next()) |part| {
        if (part.len == 0) {
            continue;
        }
        try parts.append(part);
    }
    return try parts.toOwnedSlice();
}

fn cdfunc(al: Allocator, rest: []const u8, writer: anytype, reader: anytype) void {
    _ = reader;
    const args = parse(al, rest);
    if (args.items.len == 1) {
        const home = std.posix.getenv("HOME");
        if (home == null) {
            try writer.writeAll("$HOME is not set\n");
            return;
        } else {
            _ = std.os.linux.chdir(home.?.ptr);
        }
        return;
    }
    if (args.items.len != 2) {
        try writer.writeAll("Too many args for cd command\n");
        return;
    }
    const a = args.items[1];
    var arg: [:0]u8 = try al.allocSentinel(u8, a.len + 1, 0);
    arg[a.len] = 0;
    @memcpy(arg[0 .. arg.len - 1], a);
    _ = std.os.linux.chdir(arg.ptr);
}

const ops: []Op = &.{.{}};

const Mode = enum {
    insert,
    normal,
};

pub fn main() !void {
    const al = std.heap.page_allocator;

    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    const writer = tty.writer();
    const reader = tty.reader();

    const original_termios = try std.posix.tcgetattr(tty.handle);
    const handle = tty.handle;
    try uncook(original_termios, handle, writer);
    defer cook(original_termios, handle, writer) catch unreachable;

    // try writer.writeAll(SCREEN_ALTERNATE_ENABLE);
    // defer writer.writeAll(SCREEN_ALTERNATE_DISABLE) catch unreachable;

    try writer.writeAll(KITTY_START);
    defer writer.writeAll(KITTY_STOP) catch unreachable;
    var i: usize = 0;
    var mode = Mode.insert;
    var buf = std.ArrayList(u8).init(al);
    while (true) {
        const c = try read(reader);
        switch (c) {
            Form.char => |char| {
                if (char == 'q') {
                    break;
                }
                if (mode == .normal) {
                    if (char == 'i') {
                        mode = .insert;
                    } else if (char == 'h' and i > 0) {
                        try writer.writeAll(CSI ++ "1D");
                        i -= 1;
                    } else if (char == 'l' and i < buf.items.len) {
                        try writer.writeAll(CSI ++ "1C");
                        i += 1;
                    }
                } else {
                    try writer.writeByte(char);
                    if (i == buf.items.len) {
                        try buf.append(char);
                    } else {
                        try buf.insert(i, char);
                    }
                    i += 1;
                }
            },
            Form.backspace => {
                if (i > 0) {
                    try writer.writeAll(CSI ++ "1D");
                    if (mode == .insert) {
                        try writer.writeAll(" " ++ CSI ++ "1D");
                    }
                    i -= 1;
                }
            },
            Form.esc => {
                mode = .normal;
            },
            Form.enter => {
                try writer.print("zish> {s}\n\r", .{buf.items});
            },
            else => {},
        }
        try writer.writeAll(CSI ++ "s");
        try writer.print(CSI ++ "1B" ++ CSI ++ "2K\r{any} i:{any} mode:{}" ++ CSI ++ "1A", .{ c, i, mode });
        try writer.writeAll(CSI ++ "u");
    }
}

const Form = union(enum) { char: u8, esc, enter, backspace, unknown };

fn read(reader: anytype) !Form {
    var buf: [1]u8 = undefined;
    _ = try reader.read(&buf);
    if (buf[0] == '\x1b') {
        _ = try reader.read(&buf);
        if (buf[0] != '[') {
            return Form.unknown;
        }
        _ = try reader.read(&buf);
        if (buf[0] == '2') {
            _ = try reader.read(&buf);
            _ = try reader.read(&buf);
            return Form.esc;
        }
    }
    if (buf[0] == 0x7f) {
        return Form.backspace;
    }
    if (buf[0] == 13) {
        return Form.enter;
    }
    return .{ .char = buf[0] };
}

fn uncook(orij: std.posix.termios, handle: std.fs.File.Handle, writer: anytype) !void {
    var raw = orij;
    // https://zig.news/lhp/want-to-create-a-tui-application-the-basics-of-uncooked-terminal-io-17gm
    //   ECHO: Stop the terminal from displaying pressed keys.
    // ICANON: Disable canonical ("cooked") input mode. Allows us to read inputs
    //         byte-wise instead of line-wise.
    //   ISIG: Disable signals for Ctrl-C (SIGINT) and Ctrl-Z (SIGTSTP), so we
    //         can handle them as "normal" escape sequences.
    // IEXTEN: Disable input preprocessing. This allows us to handle Ctrl-V,
    //         which would otherwise be intercepted by some terminals.
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    //   IXON: Disable software control flow. This allows us to handle Ctrl-S
    //         and Ctrl-Q.
    //  ICRNL: Disable converting carriage returns to newlines. Allows us to
    //         handle Ctrl-J and Ctrl-M.
    // BRKINT: Disable converting sending SIGINT on break conditions. Likely has
    //         no effect on anything remotely modern.
    //  INPCK: Disable parity checking. Likely has no effect on anything
    //         remotely modern.
    // ISTRIP: Disable stripping the 8th bit of characters. Likely has no effect
    //         on anything remotely modern.
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;

    // Disable output processing. Common output processing includes prefixing
    // newline with a carriage return.
    raw.oflag.OPOST = false;

    // Set the character size to 8 bits per byte. Likely has no efffect on
    // anything remotely modern.
    raw.cflag.CSIZE = .CS8;

    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    try posix.tcsetattr(handle, .FLUSH, raw);
    _ = writer;
    // try writer.writeAll(CURSOR_HIDE); // Hide the cursor.
    // try writer.writeAll(CURSOR_SAVE); // Save cursor position.
    // try writer.writeAll(SCREEN_SAVE); // Save screen.
    // try writer.writeAll(SCREEN_ALTERNATE_ENABLE); // Enable alternative buffer.
}

const CSI = "\x1B[";
const KITTY_START = "\x1B[>1u";
const KITTY_STOP = "\x1B[<u";

const CURSOR_HIDE = "\x1B[?25l";
const CURSOR_SHOW = "\x1B[?25h";

const CURSOR_SAVE = "\x1B[s";
const CURSOR_RESTORE = "\x1B[u";

const SCREEN_SAVE = "\x1B[?47h";
const SCREEN_RESTORE = "\x1B[?47l";

const SCREEN_ALTERNATE_ENABLE = "\x1B[?1049h";
const SCREEN_ALTERNATE_DISABLE = "\x1B[?1049l";

fn cook(orij: std.posix.termios, handle: std.fs.File.Handle, writer: anytype) !void {
    try posix.tcsetattr(handle, .FLUSH, orij);
    _ = writer;
    // try writer.writeAll(CURSOR_SHOW);
    // try writer.writeAll(SCREEN_ALTERNATE_DISABLE); // Disable alternative buffer.
    // try writer.writeAll(SCREEN_RESTORE); // Restore screen.
    // try writer.writeAll(CURSOR_RESTORE); // Restore cursor position.

}

pub fn old_main() !void {
    const out = std.io.getStdOut().writer();
    const in = std.io.getStdIn().reader();
    const al = std.heap.page_allocator;
    // var gpa = std.heap.GeneralPurposeAllocator(.{ .retain_metadata = true, .verbose_log = true, .safety = true }){};
    // defer gpa.deinit();
    // const al = gpa.allocator();

    const tzoffset = -5;
    var lastoutput: u8 = 0;
    var arena = std.heap.ArenaAllocator.init(al);
    const aral = arena.allocator();
    while (true) {
        _ = arena.reset(.retain_capacity);

        const p = try ps(aral, tzoffset, lastoutput);
        try out.writeAll(p);

        //https://zig.news/lhp/want-to-create-a-tui-application-the-basics-of-uncooked-terminal-io-17gm
        //https://github.com/xyaman/mibu
        const input = try in.readUntilDelimiterAlloc(al, '\n', 1000000);
        defer al.free(input);
        // const input = try in.read
        var args = std.ArrayList([]const u8).init(al);
        defer args.deinit();
        var argsplitter = std.mem.splitScalar(u8, input, ' ');
        while (argsplitter.next()) |a| {
            if (a.len == 0) {
                continue;
            }
            try args.append(a);
        }
        // undo raw mode
        lastoutput = (try run(aral, args, out)).Exited;
    }
}

fn run(al: Allocator, args: std.ArrayList([]const u8), out: anytype) !std.process.Child.Term {
    var defaultTerm = std.process.Child.Term{ .Exited = 0 };
    if (args.items.len == 0) {
        return defaultTerm;
    }
    if (std.mem.eql(u8, args.items[0], "cd")) {
        if (args.items.len == 1) {
            const home = std.posix.getenv("HOME");
            if (home == null) {
                try out.writeAll("$HOME is not set\n");
                defaultTerm.Exited = 1;
                return defaultTerm;
            } else {
                _ = std.os.linux.chdir(home.?.ptr);
            }
            return defaultTerm;
        }
        if (args.items.len != 2) {
            try out.writeAll("Too many args for cd command\n");
            defaultTerm.Exited = 1;
            return defaultTerm;
        }
        const a = args.items[1];
        var arg: [:0]u8 = try al.allocSentinel(u8, a.len + 1, 0);
        arg[a.len] = 0;
        @memcpy(arg[0 .. arg.len - 1], a);
        _ = std.os.linux.chdir(arg.ptr);
        return defaultTerm;
    }
    const shell = std.posix.getenv("SHELL").?;
    const jargs = try join(al, args.items, " ");
    var child = std.process.Child.init(&.{ shell, "-c", jargs }, al);
    try child.spawn();
    return try child.wait();
}

fn join(al: Allocator, strs: [][]const u8, sep: []const u8) ![]u8 {
    var arr = std.ArrayList(u8).init(al);
    var i: usize = 0;
    while (i < strs.len - 1) : (i += 1) {
        try arr.appendSlice(strs[i]);
        try arr.appendSlice(sep);
    }
    try arr.appendSlice(strs[strs.len - 1]);
    return try arr.toOwnedSlice();
}

// need to freeeeeeeee
fn ps(al: Allocator, tzoffset: i4, lastoutput: u8) ![]u8 {
    var arr = std.ArrayList(u8).init(al);
    const t = std.time.timestamp();
    const tm = tmfromunix(t, tzoffset);
    const h = std.fmt.digits2(@intCast(tm.hour));
    const m = std.fmt.digits2(@intCast(tm.minute));
    const s = std.fmt.digits2(@intCast(tm.second));
    const res = try std.fmt.allocPrint(al, "{s}:{s}:{s} ", .{ h, m, s });
    defer al.free(res);
    try arr.appendSlice(res);

    const user = std.posix.getenv("USER") orelse "NO $USER";
    const hostname = std.posix.getenv("HOSTNAME") orelse "NO $HOSTNAME";
    const namestr = try std.fmt.allocPrint(al, "{s}@{s} ", .{ user, hostname });
    defer al.free(namestr);
    try arr.appendSlice(namestr);

    const path = try std.fs.cwd().realpathAlloc(al, ".");
    defer al.free(path);
    try arr.appendSlice(path);

    if (lastoutput != 0) {
        const o = try std.fmt.allocPrint(al, " [{d}]", .{lastoutput});
        try arr.appendSlice(o);
    }

    const arrow = "\n> ";
    try arr.appendSlice(arrow);

    return try arr.toOwnedSlice();
}

const Tm = struct {
    hour: i64,
    minute: i64,
    second: i64,
};

fn tmfromunix(u: i64, offset: i4) Tm {
    var t = std.mem.zeroes(Tm);
    t.second = @mod(u, std.time.s_per_min);
    t.minute = @mod(u, std.time.s_per_hour);
    t.minute = @divFloor(t.minute, 60);
    t.hour = @mod(u, std.time.s_per_day);
    t.hour = @divFloor(t.hour, std.time.s_per_hour);
    t.hour += offset;
    return t;
}

test tmfromunix {
    const ts = 1717429415;
    const tm = tmfromunix(ts, -5);
    const expected = Tm{ .hour = 10, .minute = 43, .second = 35 };
    try std.testing.expectEqual(expected, tm);
}
