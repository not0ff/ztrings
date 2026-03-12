const std = @import("std");
const build_options = @import("build_options");

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
    print_loc_format: ?u8 = null,
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
                self.print_loc_format = argv[index][0];
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

    for (args.files) |file| {
        try scanFile(file, args, stdout);
    }
}

/// Formats output string based on provided args and prints it to writer
fn printString(s: String, filename: [:0]u8, args: Args, writer: *std.Io.Writer) !void {
    // not the cleanest approach but is simple and reliable
    if (args.print_filename) {
        if (args.print_loc_format) |f| switch (f) {
            'o' => try writer.print("{s}    {o} {s}\n", .{ filename, s.pos, s.string }),
            'd' => try writer.print("{s}    {d} {s}\n", .{ filename, s.pos, s.string }),
            'x' => try writer.print("{s}    {x} {s}\n", .{ filename, s.pos, s.string }),
            else => unreachable,
        } else try writer.print("{s}    {s}\n", .{ filename, s.string });
    } else if (args.print_loc_format) |f| switch (f) {
        'o' => try writer.print("{o} {s}\n", .{ s.pos, s.string }),
        'd' => try writer.print("{d} {s}\n", .{ s.pos, s.string }),
        'x' => try writer.print("{x} {s}\n", .{ s.pos, s.string }),
        else => unreachable,
    } else {
        try writer.print("{s}\n", .{s.string});
    }
}

/// Reads file in chunks scanning them for strings and writing formatted output to writer
fn scanFile(path: [:0]u8, args: Args, writer: *std.Io.Writer) !void {
    const file = try std.fs.cwd().openFileZ(path, .{ .mode = .read_only });
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    var carry_buf: [64 * 1024]u8 = undefined;
    var carry_len: usize = 0;
    if (args.min_len > buf.len or args.min_len > carry_buf.len)
        return error.MinLenTooLarge;

    while (true) {
        // leave space for potential carry
        const read = try file.readAll(buf[carry_len..]);
        if (read == 0) break;
        if (carry_len + read > buf.len) return error.BufferOverflow;

        // does nothing if carry_len == 0
        @memmove(buf[0..carry_len], carry_buf[0..carry_len]);
        const bytes = buf[0 .. carry_len + read];

        var iter: StringIterator = .{ .bytes = bytes, .min_len = args.min_len };
        while (iter.next()) |next| switch (next) {
            .string => |s| try printString(s, path, args, writer),
            .carry => |c| {
                // can occur if size of the carry buffer is smaller than the read buffer
                if (c.len > carry_buf.len) return error.CarryTooLarge;
                carry_len = c.len;
                @memmove(carry_buf[0..carry_len], c[0..carry_len]);
            },
        };
    }
}

const String = struct {
    string: []u8,
    pos: usize,
};

const NextString = union(enum) {
    string: String,
    carry: []u8,
};

// Iterator for yielding strings from bytes
const StringIterator = struct {
    bytes: []u8,
    min_len: usize,
    index: usize = 0,

    /// Iterates over bytes and yields found strings with length equal or larger than min_len
    fn next(self: *StringIterator) ?NextString {
        var start: ?usize = null;
        for (self.bytes[self.index..], self.index..) |byte, i| {
            self.index += 1;
            if (std.ascii.isPrint(byte)) {
                if (start == null) start = i;
            } else if (start) |s| {
                start = null;
                const len = i - s;
                if (len >= self.min_len) return NextString{ .string = .{ .string = self.bytes[s..i], .pos = s } };
            }
        }
        // return string terminated by the end of buffer as carry
        if (start) |s| {
            const len = self.bytes.len - s;
            if (len >= self.min_len) return NextString{ .carry = self.bytes[s..] };
        }
        return null;
    }
};
