const std = @import("std");
const build_options = @import("build_options");

const USAGE_STR =
    \\Usage: {s} [option(s)] [files(s)]
    \\
    \\Options:
    \\  -f               Print the name of the file before each string
    \\  -n min-len       The minimum number of characters to print a string (default: 4)
    \\  -t {{o,d,x}}       Print the location of string in the file in base 8, 10 or 16
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

    const ArgParseError = error{ MissingArgs, InvalidArgs };

    // parse argv array into the struct fields
    pub fn parseArgs(self: *Args, argv: [][:0]u8) ArgParseError!void {
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
                if (index + 1 >= argv.len) {
                    return error.MissingArgs;
                }
                index += 1;
                self.min_len = std.fmt.parseInt(usize, argv[index], 10) catch {
                    return error.InvalidArgs;
                };
            } else if (std.mem.eql(u8, argv[index], "-t")) {
                if (index + 1 >= argv.len) {
                    return error.MissingArgs;
                }
                index += 1;
                if (!(std.mem.eql(u8, argv[index], "o") or std.mem.eql(u8, argv[index], "d") or std.mem.eql(u8, argv[index], "x"))) {
                    return error.InvalidArgs;
                }
                self.print_loc_format = argv[index][0];
            }
            index += 1;
        }

        // parse positional arguments
        if (argv.len - index < 1) {
            return error.MissingArgs;
        }

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
}
