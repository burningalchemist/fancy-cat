const std = @import("std");

fn addMupdfStatic(exe: *std.Build.Step.Compile, b: *std.Build, location: []const u8) void {
    exe.root_module.addIncludePath(b.path("deps/mupdf/include"));

    exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{location}) });
    exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libmupdf.a", .{location}) });
    exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libmupdf-third.a", .{location}) });

    exe.root_module.link_libc = true;
}

fn addMupdfDynamic(exe: *std.Build.Step.Compile, target: std.Target) void {
    if (target.os.tag == .macos and target.cpu.arch == .aarch64) {
        exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    } else if (target.os.tag == .macos and target.cpu.arch == .x86_64) {
        exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    } else if (target.os.tag == .linux) {
        exe.root_module.addIncludePath(.{ .cwd_relative = "/home/linuxbrew/.linuxbrew/include" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/home/linuxbrew/.linuxbrew/lib" });

        const linux_libs = [_][]const u8{
            "mupdf-third", "harfbuzz",
            "freetype",    "jbig2dec",
            "jpeg",        "openjp2",
            "gumbo",       "mujs",
        };
        for (linux_libs) |lib| exe.root_module.linkSystemLibrary(lib, .{});
    }
    exe.root_module.linkSystemLibrary("mupdf", .{});
    exe.root_module.linkSystemLibrary("z", .{});
    exe.root_module.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const allocator = std.heap.page_allocator;

    var useVendorMupdf = true;
    const prefix = "./local";
    const location = "./deps/mupdf/local";

    var threaded: std.Io.Threaded = .init(b.allocator, .{});
    defer threaded.deinit();

    std.Io.Dir.cwd().access(threaded.io(), "./deps/mupdf/Makefile", .{}) catch |err| {
        if (err == error.FileNotFound) {
            useVendorMupdf = false;
        } else {
            std.debug.print("Error: {s}\n", .{@errorName(err)});
            return;
        }
    };

    var make_args: std.ArrayList([]const u8) = .empty;
    defer make_args.deinit(allocator);

    make_args.append(allocator, "make") catch unreachable;

    // use as many cores as possible by default (like zig) I dont know how to check for j<N> arg
    const cpu_count = std.Thread.getCpuCount() catch 1;
    make_args.append(allocator, b.fmt("-j{d}", .{cpu_count})) catch unreachable;

    make_args.append(allocator, "-C") catch unreachable;
    make_args.append(allocator, "deps/mupdf") catch unreachable;

    if (target.result.os.tag == .linux) {
        make_args.append(allocator, "HAVE_X11=no") catch unreachable;
        make_args.append(allocator, "HAVE_GLUT=no") catch unreachable;
    }

    make_args.append(allocator, "XCFLAGS=-w -DTOFU -DTOFU_CJK -DFZ_ENABLE_PDF=1 " ++
        "-DFZ_ENABLE_XPS=0 -DFZ_ENABLE_SVG=0 -DFZ_ENABLE_CBZ=0 " ++
        "-DFZ_ENABLE_IMG=0 -DFZ_ENABLE_HTML=0 -DFZ_ENABLE_EPUB=0") catch unreachable;
    make_args.append(allocator, "tools=no") catch unreachable;
    make_args.append(allocator, "apps=no") catch unreachable;

    const prefix_arg = b.fmt("prefix={s}", .{prefix});
    make_args.append(allocator, prefix_arg) catch unreachable;
    make_args.append(allocator, "install") catch unreachable;

    const mupdf_build_step = b.addSystemCommand(make_args.items);

    const exe = b.addExecutable(.{
        .name = "fancy-cat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.headerpad_max_install_names = true;

    if (target.result.os.tag == .macos) exe.root_module.linkFramework("CoreGraphics", .{});
    if (target.result.os.tag == .macos) exe.root_module.linkFramework("CoreGraphics", .{});

    const deps = .{
        .vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }),
        .fzwatch = b.dependency("fzwatch", .{ .target = target, .optimize = optimize }),
        .fastb64z = b.dependency("fastb64z", .{ .target = target, .optimize = optimize }),
    };

    // Set up C Translation
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    if (useVendorMupdf) {
        translate_c.addIncludePath(b.path("deps/mupdf/include"));
    } else {
        if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64) {
            translate_c.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        } else if (target.result.os.tag == .macos and target.result.cpu.arch == .x86_64) {
            translate_c.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        } else if (target.result.os.tag == .linux) {
            translate_c.addIncludePath(.{ .cwd_relative = "/home/linuxbrew/.linuxbrew/include" });
        }
    }
    translate_c.addIncludePath(b.path("src/mupdf-z"));
    const c_mod = translate_c.createModule();

    if (target.result.os.tag == .macos) {
        exe.root_module.linkFramework("CoreGraphics", .{});
        exe.root_module.linkFramework("CoreServices", .{});
    }

    deps.fzwatch.module("fzwatch").addImport("c", c_mod);

    exe.root_module.addImport("fzwatch", deps.fzwatch.module("fzwatch"));
    exe.root_module.addImport("fastb64z", deps.fastb64z.module("fastb64z"));
    exe.root_module.addImport("vaxis", deps.vaxis.module("vaxis"));
    exe.root_module.addImport("c", c_mod);

    exe.root_module.addAnonymousImport("metadata", .{ .root_source_file = b.path("build.zig.zon") });

    if (useVendorMupdf) {
        exe.step.dependOn(&mupdf_build_step.step);
        addMupdfStatic(exe, b, location);
        b.installArtifact(exe);
        b.getInstallStep().dependOn(&mupdf_build_step.step);
    } else {
        addMupdfDynamic(exe, target.result);
        b.installArtifact(exe);
    }

    exe.root_module.addIncludePath(.{ .cwd_relative = "src/mupdf-z" });
    exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = "src/mupdf-z/fitz-z.c" } });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();

    b.step("run", "Run the app").dependOn(&run_cmd.step);
}
