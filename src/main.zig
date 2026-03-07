const std = @import("std");
const Allocator = std.mem.Allocator;
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

const Args = struct {
    print_filename: bool = false,
    min_len: usize = 4,
    print_loc_format: u8 = undefined,
    print_help: bool = false,
    print_version: bool = false,
    files: [][:0]u8 = undefined,

    const ArgParseError = error{ MissingArgs, InvalidArgs, NotImplemented };

    // parse argv array into the struct fields
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
                // self.print_filename = true;
                return error.NotImplemented;
            } else if (std.mem.eql(u8, argv[index], "-n")) {
                if (index + 1 >= argv.len) return error.MissingArgs;
                index += 1;
                self.min_len = std.fmt.parseInt(usize, argv[index], 10) catch {
                    return error.InvalidArgs;
                };
                if (self.min_len < 1 or self.min_len >= 1024) return error.InvalidArgs;
            } else if (std.mem.eql(u8, argv[index], "-t")) {
                // if (index + 1 >= argv.len) return error.MissingArgs;
                // index += 1;
                // if (!(std.mem.eql(u8, argv[index], "o") or std.mem.eql(u8, argv[index], "d") or std.mem.eql(u8, argv[index], "x"))) {
                //     return error.InvalidArgs;
                // }
                // self.print_loc_format = argv[index][0];
                return error.NotImplemented;
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

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
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

    const allocator = std.heap.page_allocator;
    for (args.files) |file| {
        const bytes = readFile(file, allocator) catch |err| {
            try stdout.print("Cannot read file {s}: {}\n", .{ file, err });
            return;
        };
        defer allocator.free(bytes);

        var iter = StringIterator{ .bytes = bytes, .min_len = args.min_len };
        while (iter.next()) |string| {
            try stdout.print("{s}\n", .{string});
        }
    }
}

// read whole file into allocated buffer, needs to be free'd by the caller
fn readFile(path: [:0]const u8, allocator: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFileZ(path, .{ .mode = .read_only });
    defer file.close();

    var buf: [4 * 1024]u8 = undefined;
    var file_reader = file.reader(&buf);
    const reader = &file_reader.interface;

    const stat = try file.stat();
    const bytes = try reader.readAlloc(allocator, stat.size);
    return bytes;
}

// iterates over bytes and returns found strings with length equal or larger than min_len
const StringIterator = struct {
    bytes: []u8,
    min_len: usize,
    index: usize = 0,

    fn next(self: *StringIterator) ?[]u8 {
        var start: ?usize = null;
        for (self.bytes[self.index..], self.index..) |byte, i| {
            self.index += 1;
            if (std.ascii.isPrint(byte)) {
                if (start == null) start = i;
            } else if (start) |s| {
                start = null;
                const len = i - s;
                if (len >= self.min_len) return self.bytes[s..i];
            }
        }
        // handle string terminated by EOF
        if (start) |s| {
            const len = self.bytes.len - s;
            if (len >= self.min_len) return self.bytes[s..];
        }
        return null;
    }
};
