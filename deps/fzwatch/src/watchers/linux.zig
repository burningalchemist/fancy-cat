const std = @import("std");
const interfaces = @import("interfaces.zig");
const linux = std.os.linux;

pub const LinuxWatcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wd_to_path: std.AutoHashMap(i32, []const u8),
    path_to_wd: std.StringHashMap(i32),
    file_count: u32,
    fd: i32,
    callback: ?*const interfaces.Callback,
    context: ?*anyopaque,
    running: bool,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !LinuxWatcher {
        const fd = std.os.linux.inotify_init1(linux.IN.NONBLOCK);
        errdefer std.os.linux.close(fd);

        return LinuxWatcher{
            .allocator = allocator,
            .io = io,
            .wd_to_path = std.AutoHashMap(i32, []const u8).init(allocator),
            .path_to_wd = std.StringHashMap(i32).init(allocator),
            .file_count = 0,
            .fd = @intCast(fd),
            .callback = null,
            .context = null,
            .running = false,
        };
    }

    pub fn deinit(self: *LinuxWatcher) void {
        self.stop();
        self.wd_to_path.deinit();
        self.path_to_wd.deinit();
        _ = std.os.linux.close(self.fd);
    }

    pub fn addFile(self: *LinuxWatcher, path: []const u8) !void {
        try self._addFile(path);
        self.file_count += 1;
    }

    fn _addFile(self: *LinuxWatcher, path: []const u8) !void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len > path_buf.len) {
            return error.PathTooLong;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0; // Null-terminate the path
        const path_ptr = path_buf[0..path.len :0].ptr; // Get a pointer to the null-terminated path
        const rc = std.os.linux.inotify_add_watch(
            self.fd,
            path_ptr,
            linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.MOVE_SELF |
                linux.IN.DELETE_SELF | linux.IN.IGNORED,
        );

        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return std.posix.unexpectedErrno(err);
        }
        const wd: i32 = @intCast(rc);

        try self.wd_to_path.put(wd, path);
        try self.path_to_wd.put(path, wd);
        self.file_count += 1;
    }

    pub fn removeFile(self: *LinuxWatcher, path: []const u8) !void {
        if (self.path_to_wd.get(path)) |wd| {
            _ = std.os.linux.inotify_rm_watch(self.fd, wd);
            _ = self.path_to_wd.remove(path);
            _ = self.wd_to_path.remove(wd);
            self.file_count -= 1;
        }
    }

    pub fn getNumberOfFilesBeingWatched(self: *LinuxWatcher) u32 {
        std.debug.assert(self.file_count == self.wd_to_path.count());
        std.debug.assert(self.file_count == self.path_to_wd.count());
        return self.file_count;
    }

    pub fn setCallback(
        self: *LinuxWatcher,
        callback: interfaces.Callback,
        context: ?*anyopaque,
    ) void {
        self.callback = callback;
        self.context = context;
    }

    pub fn start(self: *LinuxWatcher, opts: interfaces.Opts) !void {
        // TODO add polling instead of busy waiting
        if (self.file_count == 0) return error.NoFilesToWatch;

        self.running = true;
        var buffer: [65536]u8 = undefined;

        while (self.running) {
            const length = std.posix.read(
                self.fd,
                &buffer,
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    const sleep_ns: u64 = @intFromFloat(@as(f64, opts.latency) * std.time.ns_per_s);
                    try self.io.sleep(.fromNanoseconds(sleep_ns), .awake);
                    continue;
                },
                else => {
                    return err;
                },
            };

            // in bytes
            var i: usize = 0;
            while (i < length) {
                const ev_ptr: *align(1) linux.inotify_event =
                    @ptrCast(buffer[i..][0..@sizeOf(linux.inotify_event)].ptr);

                const ev = ev_ptr.*;
                const step = @sizeOf(linux.inotify_event) + ev.len;

                const rec_size = @sizeOf(linux.inotify_event) + ev.len;
                if (i + rec_size > length) break;

                const path = self.wd_to_path.get(ev.wd) orelse break;

                // Editors like vim create temporary files when saving
                // So we have to re-add the file to the watcher
                if (ev.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
                    linux.IN.IGNORED) != 0)
                {
                    _ = self.wd_to_path.remove(ev.wd);
                    _ = self.path_to_wd.remove(path);
                    try self._addFile(path);
                }

                if (self.callback) |callback| callback(self.context, .modified);

                i += step;
            }
        }
    }

    pub fn stop(self: *LinuxWatcher) void {
        self.running = false;
    }
};
