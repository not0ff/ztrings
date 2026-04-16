//     ztrings - retrieve printable strings from files
//     Copyright (C) 2026-present  Not0ff
//
//     This program is free software: you can redistribute it and/or modify
//     it under the terms of the GNU General Public License as published by
//     the Free Software Foundation, either version 3 of the License, or
//     (at your option) any later version.
//
//     This program is distributed in the hope that it will be useful,
//     but WITHOUT ANY WARRANTY; without even the implied warranty of
//     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//     GNU General Public License for more details.
//
//     You should have received a copy of the GNU General Public License
//     along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

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
    min_len: usize = 4,
    loc_format: ?u8 = null,
    print_filename: bool = false,
    print_help: bool = false,
    print_version: bool = false,
    files: [][:0]const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena;
    const allocator = arena.allocator();

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var args_parser: ArgsParser = .init(init.minimal.args, allocator);
    const args = args_parser.parse() catch |err| {
        switch (err) {
            error.InvalidArgs => try stdout.writeAll("error: invalid arguments provided!\n"),
            error.MissingArgs => try stdout.writeAll("error: missing arguments!\n"),
            error.NotImplemented => try stdout.writeAll("error: option not implemented!\n"),
            else => try stdout.writeAll("error: cannot parse args\n"),
        }
        return;
    };

    if (args.print_help) {
        try stdout.print(USAGE_STR, .{build_options.exe_name});
        return;
    } else if (args.print_version) {
        try stdout.print("{s} {s}\n", .{ build_options.exe_name, build_options.version });
        return;
    }

    var format: FormattedWriter = .{
        .writer = stdout,
        .loc_format = args.loc_format,
    };
    var writer = format.Writer();

    const cwd = std.Io.Dir.cwd();
    for (args.files) |path| {
        const file = try cwd.openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var file_reader = file.reader(io, &.{});
        const reader = &file_reader.interface;

        if (args.print_filename) format.setFilename(path);
        try copyStrings(READ_BUFFER_SIZE, args.min_len, reader, &writer);
    }
}

const ArgsParser = struct {
    args: std.process.Args,
    allocator: std.mem.Allocator,

    const ParseError = error{ MissingArgs, InvalidArgs, NotImplemented, OutOfMemory };

    fn init(args: std.process.Args, allocator: std.mem.Allocator) ArgsParser {
        return ArgsParser{ .args = args, .allocator = allocator };
    }

    fn parse(self: *ArgsParser) ParseError!Args {
        var args = Args{ .files = &[_][:0]const u8{} };

        var it = self.args.iterate();
        _ = it.next();
        while (it.next()) |arg| {
            if (arg[0] != '-') {
                args.files = blk: {
                    var files: std.ArrayList([:0]const u8) = .empty;
                    defer files.deinit(self.allocator);

                    try files.append(self.allocator, arg);
                    while (it.next()) |file| {
                        try files.append(self.allocator, file);
                    }
                    break :blk try files.toOwnedSlice(self.allocator);
                };
                continue;
            }

            if (std.mem.eql(u8, arg, "-h")) {
                args.print_help = true;
                break;
            } else if (std.mem.eql(u8, arg, "-v")) {
                args.print_version = true;
                break;
            } else if (std.mem.eql(u8, arg, "-f")) {
                args.print_filename = true;
            } else if (std.mem.eql(u8, arg, "-n")) {
                const next = it.next() orelse return error.InvalidArgs;
                const parsed = std.fmt.parseInt(usize, next, 10) catch return error.InvalidArgs;
                if (parsed < 1 or parsed >= 1024) return error.InvalidArgs;
                args.min_len = parsed;
            } else if (std.mem.eql(u8, arg, "-t")) {
                const t = it.next() orelse return error.InvalidArgs;
                if (!(std.mem.eql(u8, t, "o") or std.mem.eql(u8, t, "d") or std.mem.eql(u8, t, "x"))) {
                    return error.InvalidArgs;
                }
                args.loc_format = t[0];
            } else return error.InvalidArgs;
        } else {
            if (args.files.len <= 0) return error.MissingArgs;
        }
        return args;
    }
};

/// Iterator yielding ascii-printable strings found in bytes
const StringIterator = struct {
    bytes: []u8,
    min_len: usize,
    index: usize = 0,

    const StringInfo = struct {
        bytes: []u8,
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

/// Default writer writes unformatted string to provided writer
const DefaultWriter = struct {
    writer: *std.Io.Writer,

    fn write(ptr: *anyopaque, s: String) error{WriteFailed}!void {
        const self: *DefaultWriter = @ptrCast(@alignCast(ptr));
        try self.writer.writeAll(s.bytes);
    }

    fn Writer(self: *DefaultWriter) StringWriter {
        return .{
            .ptr = self,
            .writeFn = write,
        };
    }
};

/// Writes location as a string formatted hex value followed by a newline
///
/// i.e. index 0 -> 0x0; index 255  -> 0xFF
const LocationWriter = struct {
    writer: *std.Io.Writer,

    fn write(ptr: *anyopaque, s: String) error{WriteFailed}!void {
        const self: *LocationWriter = @ptrCast(@alignCast(ptr));
        try self.writer.print("0x{X}\n", .{s.loc});
    }

    fn Writer(self: *LocationWriter) StringWriter {
        return .{
            .ptr = self,
            .writeFn = write,
        };
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
///
/// min_len must be less or equal to read_len
fn copyStrings(comptime read_len: usize, min_len: usize, reader: *std.Io.Reader, writer: *StringWriter) !void {
    if (min_len > read_len)
        return error.BufferTooSmall;

    var buf: [read_len * 2]u8 = undefined;

    var carry_len: usize = 0;
    var loc_offset: usize = 0;
    while (true) {
        // leave space for potential carry
        const read = try reader.readSliceShort(buf[carry_len..]);
        if (read == 0) break;

        var iter: StringIterator = .{ .bytes = buf[0 .. carry_len + read], .min_len = min_len };
        while (iter.next()) |s| {
            carry_len = if (s.last) s.bytes.len else 0;
            if (s.last) {
                @memmove(buf[0..carry_len], s.bytes);
            } else {
                const string: String = .{ .bytes = s.bytes, .loc = s.loc + loc_offset };
                try writer.write(string);
            }
        }
        loc_offset += read;
    }

    // handle carry at the end of read buffer
    if (carry_len > 0) {
        const string: String = .{ .bytes = buf[0..carry_len], .loc = loc_offset - carry_len };
        try writer.write(string);
    }
}

/// Simple helper for testing found strings
fn expectStringsFromIter(iter: *StringIterator, exp_strings: []const []const u8, exp_loc: []const usize, exp_last: []const bool) !void {
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
    try expectStringsFromIter(
        &iter,
        &strings,
        &offsets,
        &[_]bool{false} ** strings.len,
    );

    iter = .{ .bytes = &bytes, .min_len = 7, .index = 0 };
    try expectStringsFromIter(
        &iter,
        &[_][]const u8{ "ztrings", "hello world", "AndrewK", "VeryLoooongString" },
        &[_]usize{ 93, 288, 355, 480 },
        &[_]bool{false} ** 7,
    );
}

test "test StringIterator: strings at start" {
    var bytes = [_]u8{ 'v', 'o', 'i', 'd', 0xFF, 0xFF };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 4 };
    try expectStringsFromIter(
        &iter,
        &[_][]const u8{"void"},
        &[_]usize{0},
        &[_]bool{false},
    );
}

test "test StringIterator: strings at end" {
    var bytes = [_]u8{ 0xFF, 0xFF, 't', 'h', 'e', ' ', 'e', 'n', 'd' };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 4 };
    try expectStringsFromIter(
        &iter,
        &[_][]const u8{"the end"},
        &[_]usize{2},
        &[_]bool{true},
    );
}

test "test StringIterator: strings at start and end" {
    var bytes = [_]u8{ 'a', 'b', 0xFF, 0xFF, 'c', 'd', 'e' };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 2 };
    try expectStringsFromIter(
        &iter,
        &[_][]const u8{ "ab", "cde" },
        &[_]usize{ 0, 4 },
        &[_]bool{ false, true },
    );
}

test "StringIterator: full string" {
    var bytes = [_]u8{ 'z', 't', 'r', 'i', 'n', 'g', 's' };

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 4 };

    try expectStringsFromIter(
        &iter,
        &[_][]const u8{"ztrings"},
        &[_]usize{0},
        &[_]bool{true},
    );
}

test "StringIterator: no strings" {
    var bytes: [64]u8 = undefined;
    @memset(&bytes, 0x00);

    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 1 };

    try expectStringsFromIter(
        &iter,
        &[_][]const u8{},
        &[_]usize{},
        &[_]bool{},
    );
}

test "StringIterator: empty" {
    var bytes = [_]u8{};
    var iter: StringIterator = .{ .bytes = &bytes, .min_len = 1 };

    try expectStringsFromIter(
        &iter,
        &[_][]const u8{},
        &[_]usize{},
        &[_]bool{},
    );
}

/// Helper for testing copyStrings function
fn copyStringsFromBuffer(comptime read_len: usize, min_len: usize, buffer: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(buffer);

    var write_buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&write_buf);

    var std_writer: DefaultWriter = .{ .writer = &writer };
    var str_writer = std_writer.Writer();

    try copyStrings(read_len, min_len, &reader, &str_writer);
    return writer.buffered();
}

test "copyStrings: empty" {
    try std.testing.expectEqualStrings(
        "",
        try copyStringsFromBuffer(8, 1, &[_]u8{}),
    );
}

test "copyStrings: single string" {
    try std.testing.expectEqualStrings(
        "single",
        try copyStringsFromBuffer(8, 1, &[_]u8{
            's', 'i', 'n', 'g', 'l', 'e',
        }),
    );
}

test "copyStrings: many strings at buffer start" {
    try std.testing.expectEqualStrings(
        "abc xkcd",
        try copyStringsFromBuffer(8, 1, &[_]u8{
            'a', 'b', 'c', ' ', 0xFF, 0xFF, 0xFF, 0xFF,
            'x', 'k', 'c', 'd', 0xFF, 0xFF, 0xFF, 0xFF,
        }),
    );
}

test "copyStrings: strings in middle of buffer" {
    try std.testing.expectEqualStrings(
        "abcd efg",
        try copyStringsFromBuffer(8, 1, &[_]u8{
            0xFF, 'a',  'b', 'c', 'd', 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, ' ', 'e', 'f', 0xFF, 'g',  0xFF,
        }),
    );
}

test "copyStrings: strings at buffer end" {
    try std.testing.expectEqualStrings(
        "BBS? yes!",
        try copyStringsFromBuffer(8, 1, &[_]u8{
            0xFF, 0xFF, 0xFF, 0xFF, 'B', 'B', 'S', '?',
            0xFF, 0xFF, 0xFF, ' ',  'y', 'e', 's', '!',
        }),
    );
}

test "copyStrings: string splitted by buffer" {
    try std.testing.expectEqualStrings(
        "ztrings",
        try copyStringsFromBuffer(8, 1, &[_]u8{
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 'z',  't',  'r',
            'i',  'n',  'g',  's',  0xFF, 0xFF, 0xFF, 0xFF,
        }),
    );
}

test "copyStrings: buffer too small error" {
    try std.testing.expectError(
        error.BufferTooSmall,
        copyStringsFromBuffer(8, 16, &[_]u8{
            'Z', 'i', 'g',
        }),
    );
}

test "copyStrings: location inside buffer" {
    const buffer = [_]u8{
        0xFF, 'x', 'z', 0xFF, 0xFF, '0', '1', 0xFF,
    };
    var reader: std.Io.Reader = .fixed(&buffer);

    var write_buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&write_buf);

    var std_writer: LocationWriter = .{ .writer = &writer };
    var str_writer = std_writer.Writer();

    try copyStrings(8, 2, &reader, &str_writer);
    try std.testing.expectEqualStrings("0x1\n0x5\n", writer.buffered());
}

test "copyStrings: location at buffer edges" {
    const buffer = [_]u8{
        't', 'e', 's', 't', 0xFF, 'i', 'n', 'g',
    };
    var reader: std.Io.Reader = .fixed(&buffer);

    var write_buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&write_buf);

    var std_writer: LocationWriter = .{ .writer = &writer };
    var str_writer = std_writer.Writer();

    try copyStrings(8, 3, &reader, &str_writer);
    try std.testing.expectEqualStrings("0x0\n0x5\n", writer.buffered());
}

test "copyStrings: location in many reads" {
    const buffer = [_]u8{
        't',  'e', 's',  't',  0xFF, 'i', 'n', 'g',
        0xFF, ' ', 0xFF, 0xFF, 'c',  'a', 's', 'e',
    };
    var reader: std.Io.Reader = .fixed(&buffer);

    var write_buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&write_buf);

    var std_writer: LocationWriter = .{ .writer = &writer };
    var str_writer = std_writer.Writer();

    try copyStrings(8, 1, &reader, &str_writer);
    try std.testing.expectEqualStrings("0x0\n0x5\n0x9\n0xC\n", writer.buffered());
}
