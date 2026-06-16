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
    const minimal = b.option(bool, "minimal", "Build minimal binary without bundled plugins") orelse false;
    const with_plugins = !minimal;

    // Optional extra dependency prefix (e.g. a sysroot or custom install root).
    // Adds <prefix>/include and <prefix>/lib to the search paths.
    const dep_prefix = b.option(
        []const u8,
        "dep-prefix",
        "Extra dependency prefix providing include/ and lib/ for openssl, libevent, json-c, zlib",
    );

    // Force a fully static executable (recommended with a musl target, e.g.
    // -Dtarget=x86_64-linux-musl -Dstatic).
    const force_static = b.option(bool, "static", "Link the executable fully statically") orelse false;

    // Link the C dependencies (openssl/libevent/json-c/zlib) statically while
    // keeping the executable itself dynamic. macOS cannot link libSystem
    // statically, so this is the way to produce a portable macOS binary that
    // does not require Homebrew at runtime.
    const dep_static = b.option(bool, "dep-static", "Statically link the C dependencies but keep the executable dynamic") orelse false;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (optimize != .Debug) true else null,
    });

    const core_sources = [_][]const u8{
        // core
        "main.c",        "client.c",    "config.c",   "config_toml.c", "control.c",
        "ini.c",         "msg.c",       "xfrpc.c",    "debug.c",
        "zip.c",         "commandline.c", "crypto.c", "fastpbkdf2.c",
        "utils.c",       "common.c",    "login.c",    "tls.c",
        "third_party/tomlc99/toml.c",
    };
    const proxy_sources = [_][]const u8{
        // proxy
        "proxy_tcp.c", "proxy_udp.c", "proxy_ftp.c", "proxy.c",
        "tcpmux.c", "tcp_redir.c",
    };
    const plugin_sources = [_][]const u8{
        "mongoose.c",
        "plugins/telnetd.c", "plugins/instaloader.c",
        "plugins/httpd.c",   "plugins/youtubedl.c",
    };

    const base_flags = [_][]const u8{
        "-D_GNU_SOURCE",
        "-Wall",
        "-fno-strict-aliasing",
        "-ffunction-sections",
        "-fdata-sections",
    };
    var source_list: std.ArrayList([]const u8) = .empty;
    defer source_list.deinit(b.allocator);
    source_list.appendSlice(b.allocator, &core_sources) catch @panic("OOM");
    source_list.appendSlice(b.allocator, &proxy_sources) catch @panic("OOM");
    if (with_plugins) {
        source_list.appendSlice(b.allocator, &plugin_sources) catch @panic("OOM");
    }

    var cflags: std.ArrayList([]const u8) = .empty;
    defer cflags.deinit(b.allocator);
    cflags.appendSlice(b.allocator, &base_flags) catch @panic("OOM");
    if (optimize == .Debug) cflags.append(b.allocator, "-DXFRPC_DEBUG") catch @panic("OOM");
    cflags.append(b.allocator, if (with_plugins) "-DXFRPC_WITH_PLUGINS=1" else "-DXFRPC_WITH_PLUGINS=0") catch @panic("OOM");

    mod.addCSourceFiles(.{
        .files = source_list.items,
        .flags = cflags.items,
    });
    mod.addIncludePath(b.path("."));
    mod.addIncludePath(b.path("third_party/tomlc99"));

    const os_tag = target.result.os.tag;

    // When building for macOS we need the system SDK headers (e.g.
    // <arpa/telnet.h>, which Zig's bundled libc headers do not ship). For a
    // native build Zig finds the SDK automatically, but as soon as an explicit
    // -Dtarget is given (e.g. cross-compiling x86_64 on an Apple Silicon
    // runner) it falls back to its own headers. In that case set SDKROOT, e.g.
    //   export SDKROOT=$(xcrun --show-sdk-path)
    // and we add the SDK include/lib/framework paths from it.
    if (os_tag == .macos) {
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            if (sdk.len > 0) {
                mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
                mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
                mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
            }
        }
    }

    // On macOS, dependencies are typically installed via Homebrew. Add the
    // common Apple Silicon (/opt/homebrew) and Intel (/usr/local) prefixes so
    // headers/libs are found. Skip paths that do not exist (Zig 0.16+ errors
    // on missing -L directories).
    // When an explicit dep-prefix is given (e.g. a static sysroot built by
    // scripts/build-macos-deps.sh) we skip Homebrew so that prefix is the sole,
    // authoritative source of the dependencies.
    if (os_tag == .macos and dep_prefix == null) {
        const brew_opt = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
        const pkgs = [_][]const u8{ "openssl@3", "libevent", "json-c", "zlib" };
        for (brew_opt) |root| {
            for (pkgs) |pkg| {
                addBrewPkgPaths(mod, b, root, pkg);
            }
        }
    }

    // Extra user-provided prefix (sysroot / custom install root).
    if (dep_prefix) |prefix| {
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        // OpenSSL (and some distros) install 64-bit libs under lib64.
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{prefix}) });
    }

    const link_mode: std.builtin.LinkMode = if (force_static or dep_static) .static else .dynamic;

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
        mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no, .preferred_link_mode = link_mode });
    }

    // System libraries that are separate on Linux but part of libc elsewhere.
    // On musl they all live in libc; `crypt` has no stub archive, so skip it
    // there (the rest are provided as empty stubs by Zig).
    if (os_tag == .linux) {
        for ([_][]const u8{ "pthread", "m", "dl" }) |lib| {
            mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no, .preferred_link_mode = link_mode });
        }
        if (!target.result.abi.isMusl()) {
            mod.linkSystemLibrary("crypt", .{ .use_pkg_config = .no, .preferred_link_mode = link_mode });
        }
    }

    const exe = b.addExecutable(.{
        .name = "xfrpc",
        .root_module = mod,
    });
    if (force_static) exe.linkage = .static;
    // Collect dead code/data sections produced by -ffunction/-fdata-sections.
    exe.link_gc_sections = true;
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run xfrpc");
    run_step.dependOn(&run_cmd.step);
}

fn addBrewPkgPaths(mod: *std.Build.Module, b: *std.Build, root: []const u8, pkg: []const u8) void {
    const include_dir = b.fmt("{s}/{s}/include", .{ root, pkg });
    defer b.allocator.free(include_dir);
    if (pathExists(b, include_dir)) {
        mod.addIncludePath(.{ .cwd_relative = include_dir });
    }

    const lib_dir = b.fmt("{s}/{s}/lib", .{ root, pkg });
    defer b.allocator.free(lib_dir);
    if (pathExists(b, lib_dir)) {
        mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    }
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch return false;
    return true;
}
