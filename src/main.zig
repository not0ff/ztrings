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

    var fmt_writer: FormattedWriter = .{
        .writer = stdout,
        .loc_format = args.loc_format,
    };
    var writer = fmt_writer.Writer();

    for (args.files) |path| {
        const file = try std.fs.cwd().openFileZ(path, .{ .mode = .read_only });
        defer file.close();
        var file_reader = file.reader(&.{});
        const reader = &file_reader.interface;

        if (args.print_filename) fmt_writer.setFilename(path);
        try copyStrings(args.min_len, reader, &writer);
    }
}

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

/// Iterator yielding ascii-printable strings found in bytes
const StringIterator = struct {
    bytes: []u8,
    min_len: usize,
    index: usize = 0,

    const StringInfo = struct {
        bytes: []const u8,
        loc: usize,
        last: bool = false,
    };

    fn next(self: *StringIterator) ?StringInfo {
        var start: ?usize = null;
        for (self.bytes[self.index..], self.index..) |byte, i| {
            self.index += 1;
            if (std.ascii.isPrint(byte)) {
                if (start == null) start = i;
            } else if (start) |s| {
                start = null;
                const len = i - s;
                if (len >= self.min_len) return .{
                    .bytes = self.bytes[s..i],
                    .loc = s,
                };
            }
        }
        // return string terminated by the end of buffer
        if (start) |s| {
            const len = self.bytes.len - s;
            if (len >= self.min_len) return .{
                .bytes = self.bytes[s..],
                .loc = s,
                .last = true,
            };
        }
        return null;
    }
};

/// General string type with offset location
const String = struct {
    bytes: []const u8,
    loc: usize,
};

/// Interface for writers handling found strings
const StringWriter = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, string: String) anyerror!void,

    fn write(self: StringWriter, string: String) !void {
        return self.writeFn(self.ptr, string);
    }
};

/// Writer formatting found strings by including optional filename and location
const FormattedWriter = struct {
    writer: *std.Io.Writer,
    loc_format: ?u8,
    filename: ?[]const u8 = null,

    inline fn setFilename(self: *FormattedWriter, f: []const u8) void {
        self.filename = f;
    }

    fn write(ptr: *anyopaque, s: String) error{ InvalidFormat, WriteFailed }!void {
        const self: *FormattedWriter = @ptrCast(@alignCast(ptr));
        if (self.filename) |f| {
            try self.writer.print("{s}    ", .{f});
        }
        if (self.loc_format) |fmt| switch (fmt) {
            'o' => try self.writer.print("{o} ", .{s.loc}),
            'd' => try self.writer.print("{d} ", .{s.loc}),
            'x' => try self.writer.print("{x} ", .{s.loc}),
            else => return error.InvalidFormat,
        };
        try self.writer.print("{s}\n", .{s.bytes});
    }

    fn Writer(self: *FormattedWriter) StringWriter {
        return .{
            .ptr = self,
            .writeFn = write,
        };
    }
};

/// Reads strings from Reader and writes them to StringWriter
fn copyStrings(min_len: usize, reader: *std.Io.Reader, str_writer: *StringWriter) !void {
    var buf: [READ_BUFFER_SIZE]u8 = undefined;
    if (min_len > buf.len)
        return error.MinLenTooLarge;

    var carry_len: usize = 0;
    var loc_offset: usize = 0;
    while (true) {
        // leave space for potential carry
        const read = try reader.readSliceShort(buf[carry_len..]);
        if (read == 0) break;
        if (carry_len + read > buf.len) return error.BufferOverflow;

        const bytes = buf[0 .. carry_len + read];
        carry_len = 0;

        var iter: StringIterator = .{ .bytes = bytes, .min_len = min_len };
        while (iter.next()) |s| {
            if (s.last) {
                if (s.bytes.len > buf.len) return error.CarryTooLarge;
                carry_len = s.bytes.len;
                @memmove(buf[0..carry_len], s.bytes[0..carry_len]);
            } else {
                const string: String = .{ .bytes = s.bytes, .loc = s.loc + loc_offset };
                try str_writer.write(string);
            }
        }
        loc_offset += read;
    }
}

/// Simple helper for testing found strings
fn expectStrings(iter: *StringIterator, exp_strings: []const []const u8, exp_loc: []const usize, exp_last: []const bool) !void {
    var i: usize = 0;
    while (iter.next()) |s| {
        try std.testing.expect(i < exp_strings.len);
        try std.testing.expectEqualStrings(exp_strings[i], s.bytes);
        try std.testing.expectEqual(exp_loc[i], s.loc);
        try std.testing.expectEqual(exp_last[i], s.last);
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
