const std = @import("std");

const metadata = @import("metadata");

const Context = @import("Context.zig").Context;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))) {
        try stdout.print("fancy-cat version {s}\n", .{metadata.version});
        try stdout.flush();
        return;
    }

    if (args.len < 2 or args.len > 3 or (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try stderr.writeAll("Usage: fancy-cat <path-to-pdf> <optional-page-number>\n");
        try stderr.flush();
        return;
    }

    const allocator = init.gpa;

    var app = try Context.init(allocator, io, init.environ_map, args);
    defer app.deinit();

    try app.run(io);
}
