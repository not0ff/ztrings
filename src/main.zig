const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const DEBUG = builtin.mode == .Debug;
const READ_BUFFER_SIZE = 64 * 1024;

const USAGE_STR =
    \\Usage: {s} [option(s)] [files(s)]
    \\
    \\Options:
    \\  -f               Print the name of the file before each string
    \\  -n min-len       The minimum number of characters to print a string (default: 4)
    \\  -t {{o,d,x}}     Print the location of string in the file in base 8, 10 or 16
    \\  -h               Print the program usage
    \\  -v               Print the version of the program
    \\
    \\Arguments:
    \\  file1 [ file2 file3... ]     List of files to scan
    \\
;

/// Struct holding command-line options
const Args = struct {
    print_filename: bool = false,
    min_len: usize = 4,
    loc_format: ?u8 = null,
    print_help: bool = false,
    print_version: bool = false,
    files: [][:0]u8 = undefined,

    const ArgParseError = error{ MissingArgs, InvalidArgs, NotImplemented };

    /// Parses argv array into the struct fields
    fn parseArgs(self: *Args, argv: [][:0]u8) ArgParseError!void {
        // parse optional arguments starting with a dash '-'
        var index: usize = 1;
        while (index < argv.len and argv[index][0] == '-') {
            if (std.mem.eql(u8, argv[index], "-h")) {
                self.print_help = true;
                return;
            } else if (std.mem.eql(u8, argv[index], "-v")) {
                self.print_version = true;
                return;
            } else if (std.mem.eql(u8, argv[index], "-f")) {
                self.print_filename = true;
            } else if (std.mem.eql(u8, argv[index], "-n")) {
                if (index + 1 >= argv.len) return error.MissingArgs;
                index += 1;
                self.min_len = std.fmt.parseInt(usize, argv[index], 10) catch {
                    return error.InvalidArgs;
                };
                if (self.min_len < 1 or self.min_len >= 1024) return error.InvalidArgs;
            } else if (std.mem.eql(u8, argv[index], "-t")) {
                if (index + 1 >= argv.len) return error.MissingArgs;
                index += 1;
                if (!(std.mem.eql(u8, argv[index], "o") or std.mem.eql(u8, argv[index], "d") or std.mem.eql(u8, argv[index], "x"))) {
                    return error.InvalidArgs;
                }
                self.loc_format = argv[index][0];
            }
            index += 1;
        }

        // parse positional arguments
        if (argv.len - index < 1) return error.MissingArgs;

        self.files = argv[index..];
        return;
    }
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var args = Args{};
    args.parseArgs(argv) catch |err| {
        switch (err) {
            error.InvalidArgs => try stdout.writeAll("Error: invalid arguments provided!\n"),
            error.MissingArgs => try stdout.writeAll("Error: missing arguments!\n"),
            error.NotImplemented => try stdout.writeAll("Error: option not implemented!\n"),
        }
        try stdout.print(USAGE_STR, .{build_options.exe_name});
        return;
    };

    if (args.print_help) {
        try stdout.print(USAGE_STR, .{build_options.exe_name});
        return;
    } else if (args.print_version) {
        try stdout.print("{s} {s}\n", .{ build_options.exe_name, build_options.version });
        return;
    }

    var ctx: scanCtx = .{
        .min_len = args.min_len,
        .loc_format = args.loc_format,
        .print_filename = args.print_filename,
        .debug = DEBUG,
        .filename = undefined, // updated on each file read
        .writer = stdout,
    };

    for (args.files) |path| {
        const file = try std.fs.cwd().openFileZ(path, .{ .mode = .read_only });
        defer file.close();
        var file_reader = file.reader(&.{});
        const reader = &file_reader.interface;

        ctx.filename = path;
        try scanReader(reader, ctx);
    }
}

const scanCtx = struct {
    min_len: usize,
    loc_format: ?u8,
    print_filename: bool,
    debug: bool,
    filename: []const u8,
    writer: *std.Io.Writer,

    fn print(self: scanCtx, string: []u8, loc: usize) !void {
        return try printString(string, self.loc_format, loc, self.print_filename, self.filename, self.writer);
    }

    fn log_stdout(self: scanCtx, comptime fmt: []const u8, args: anytype) !void {
        if (!DEBUG) return;
        try self.writer.print(fmt, args);
    }
};

/// Formats output string based on provided options and prints it to writer
fn printString(
    string: []u8,
    loc_format: ?u8,
    loc: usize,
    print_filename: bool,
    filename: []const u8,
    writer: *std.Io.Writer,
) error{WriteFailed}!void {
    // not the cleanest approach but is simple and reliable
    if (print_filename) {
        if (loc_format) |f| switch (f) {
            'o' => try writer.print("{s}    {o} {s}\n", .{ filename, loc, string }),
            'd' => try writer.print("{s}    {d} {s}\n", .{ filename, loc, string }),
            'x' => try writer.print("{s}    {x} {s}\n", .{ filename, loc, string }),
            else => unreachable,
        } else try writer.print("{s}    {s}\n", .{ filename, string });
    } else if (loc_format) |f| switch (f) {
        'o' => try writer.print("{o} {s}\n", .{ loc, string }),
        'd' => try writer.print("{d} {s}\n", .{ loc, string }),
        'x' => try writer.print("{x} {s}\n", .{ loc, string }),
        else => unreachable,
    } else {
        try writer.print("{s}\n", .{string});
    }
}

/// Scans chunks from reader for strings and calls print func from ctx
fn scanReader(reader: *std.Io.Reader, ctx: scanCtx) !void {
    var buf: [READ_BUFFER_SIZE]u8 = undefined;
    var carry_len: usize = 0;
    if (ctx.min_len > buf.len)
        return error.MinLenTooLarge;

    var loc_offset: usize = 0;
    while (true) {
        try ctx.log_stdout("reading new buf, carry: {d} \n", .{carry_len});
        // leave space for potential carry
        const read = try reader.readSliceShort(buf[carry_len..]);
        if (read == 0) break;
        if (carry_len + read > buf.len) return error.BufferOverflow;

        const bytes = buf[0 .. carry_len + read];
        carry_len = 0;

        var iter: StringIterator = .{ .bytes = bytes, .min_len = ctx.min_len };
        while (iter.next()) |s| {
            if (s.carry) {
                if (s.bytes.len > buf.len) return error.CarryTooLarge;
                carry_len = s.bytes.len;
                @memmove(buf[0..carry_len], s.bytes[0..carry_len]);
            } else try ctx.print(s.bytes, s.loc + loc_offset);
        }
        loc_offset += read;
        try ctx.log_stdout("offset: {x}\n", .{loc_offset});
    }
}

const String = struct {
    bytes: []u8,
    loc: usize,
    carry: bool = false,
};

// Iterator for yielding strings from bytes
const StringIterator = struct {
    bytes: []u8,
    min_len: usize,
    index: usize = 0,

    /// Iterates over bytes and yields found strings with length equal or larger than min_len
    fn next(self: *StringIterator) ?String {
        var start: ?usize = null;
        for (self.bytes[self.index..], self.index..) |byte, i| {
            self.index += 1;
            if (std.ascii.isPrint(byte)) {
                if (start == null) start = i;
            } else if (start) |s| {
                start = null;
                const len = i - s;
                if (len >= self.min_len) return String{ .bytes = self.bytes[s..i], .loc = s };
            }
        }
        // return string terminated by the end of buffer
        if (start) |s| {
            const len = self.bytes.len - s;
            if (len >= self.min_len) return String{ .bytes = self.bytes[s..], .loc = s, .carry = true };
        }
        return null;
    }
};

/// Simple helper for testing found strings
fn expectStrings(iter: *StringIterator, exp_strings: []const []const u8, exp_loc: []const usize, exp_carry: []const bool) !void {
    var i: usize = 0;
    while (iter.next()) |s| {
        try std.testing.expect(i < exp_strings.len);
        try std.testing.expectEqualStrings(exp_strings[i], s.bytes);
        try std.testing.expectEqual(exp_loc[i], s.loc);
        try std.testing.expectEqual(exp_carry[i], s.carry);
        i += 1;
    }

    try std.testing.expectEqual(exp_strings.len, i);
}

test "StringIterator: general" {
    var bytes: [512]u8 = undefined;
    @memset(&bytes, 0xFF);

    const offsets = [_]usize{ 23, 93, 130, 200, 288, 355, 480 };
    const strings = [_][]const u8{
        "zig",
        "ztrings",
        "spam",
        "foo",
        "hello world",
        "AndrewK",
        "VeryLoooongString",
    };

    for (offsets, 0..) |o, i| {
        for (strings[i], 0..) |c, j| {
            bytes[o + j] = c;
        }
    }

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 3 };
    try expectStrings(
        &iter,
        &strings,
        &offsets,
        &[_]bool{false} ** strings.len,
    );

    iter = .{ .bytes = &bytes, .min_len = 7, .index = 0 };
    try expectStrings(
        &iter,
        &[_][]const u8{ "ztrings", "hello world", "AndrewK", "VeryLoooongString" },
        &[_]usize{ 93, 288, 355, 480 },
        &[_]bool{false} ** 7,
    );
}

test "test StringIterator: strings at start" {
    var bytes = [_]u8{ 'v', 'o', 'i', 'd', 0xFF, 0xFF };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 4 };
    try expectStrings(
        &iter,
        &[_][]const u8{"void"},
        &[_]usize{0},
        &[_]bool{false},
    );
}

test "test StringIterator: strings at end" {
    var bytes = [_]u8{ 0xFF, 0xFF, 't', 'h', 'e', ' ', 'e', 'n', 'd' };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 4 };
    try expectStrings(
        &iter,
        &[_][]const u8{"the end"},
        &[_]usize{2},
        &[_]bool{true},
    );
}

test "test StringIterator: strings at start and end" {
    var bytes = [_]u8{ 'a', 'b', 0xFF, 0xFF, 'c', 'd', 'e' };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 2 };
    try expectStrings(
        &iter,
        &[_][]const u8{ "ab", "cde" },
        &[_]usize{ 0, 4 },
        &[_]bool{ false, true },
    );
}

test "StringIterator: full string" {
    var bytes = [_]u8{ 'z', 't', 'r', 'i', 'n', 'g', 's' };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 4 };

    try expectStrings(
        &iter,
        &[_][]const u8{"ztrings"},
        &[_]usize{0},
        &[_]bool{true},
    );
}

test "StringIterator: no strings" {
    var bytes: [64]u8 = undefined;
    @memset(&bytes, 0x00);

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 4 };

    try expectStrings(
        &iter,
        &[_][]const u8{},
        &[_]usize{},
        &[_]bool{},
    );
}
