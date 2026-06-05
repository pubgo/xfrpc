const std = @import("std");

// xfrpc build script for the Zig toolchain.
//
// Usage:
//   zig build                       # native build (auto-detects Homebrew deps on macOS)
//   zig build run -- -c xfrpc.ini   # build and run
//   zig build -Ddep-prefix=/path    # add <path>/include and <path>/lib for deps
//   zig build -Dtarget=x86_64-linux-gnu -Ddep-prefix=/sysroot/usr   # cross compile
//
// Dependencies (must exist for the chosen target): openssl, libevent
// (with libevent_openssl), json-c, zlib.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional extra dependency prefix (e.g. a sysroot or custom install root).
    // Adds <prefix>/include and <prefix>/lib to the search paths.
    const dep_prefix = b.option(
        []const u8,
        "dep-prefix",
        "Extra dependency prefix providing include/ and lib/ for openssl, libevent, json-c, zlib",
    );

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const sources = [_][]const u8{
        // core
        "main.c",        "client.c",    "config.c",   "control.c",
        "ini.c",         "msg.c",       "xfrpc.c",    "debug.c",
        "zip.c",         "commandline.c", "crypto.c", "fastpbkdf2.c",
        "utils.c",       "common.c",    "login.c",    "tls.c",
        // proxy
        "proxy_tcp.c",   "proxy_udp.c", "proxy_ftp.c", "proxy.c",
        "tcpmux.c",      "tcp_redir.c", "mongoose.c",
        // plugins
        "plugins/telnetd.c", "plugins/instaloader.c",
        "plugins/httpd.c",   "plugins/youtubedl.c",
    };

    const base_flags = [_][]const u8{
        "-D_GNU_SOURCE",
        "-Wall",
    };
    const debug_flags = base_flags ++ [_][]const u8{"-DXFRPC_DEBUG"};
    const cflags: []const []const u8 = if (optimize == .Debug) &debug_flags else &base_flags;

    mod.addCSourceFiles(.{
        .files = &sources,
        .flags = cflags,
    });
    mod.addIncludePath(b.path("."));

    const os_tag = target.result.os.tag;

    // On macOS, dependencies are typically installed via Homebrew. Add the
    // common Apple Silicon (/opt/homebrew) and Intel (/usr/local) prefixes so
    // headers/libs are found. Non-existent dirs only yield a harmless warning.
    if (os_tag == .macos) {
        const brew_opt = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
        const pkgs = [_][]const u8{ "openssl@3", "libevent", "json-c", "zlib" };
        for (brew_opt) |root| {
            for (pkgs) |pkg| {
                mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/{s}/include", .{ root, pkg }) });
                mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/{s}/lib", .{ root, pkg }) });
            }
        }
    }

    // Extra user-provided prefix (sysroot / custom install root).
    if (dep_prefix) |prefix| {
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    }

    // External libraries (required on every target).
    // Disable pkg-config: it resolves libevent_openssl's dependency on libevent
    // and emits a second `-levent`, producing a "duplicate linked dylib" abort
    // at runtime on macOS. We pass each library exactly once instead.
    const ext_libs = [_][]const u8{
        "ssl",
        "crypto",
        "event",
        "event_openssl",
        "json-c",
        "z",
    };
    for (ext_libs) |lib| {
        mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    }

    // System libraries that are separate on Linux but part of libc elsewhere.
    if (os_tag == .linux) {
        for ([_][]const u8{ "pthread", "m", "crypt", "dl" }) |lib| {
            mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
        }
    }

    const exe = b.addExecutable(.{
        .name = "xfrpc",
        .root_module = mod,
    });
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run xfrpc");
    run_step.dependOn(&run_cmd.step);
}
