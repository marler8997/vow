const builtin = @import("builtin");
const std = @import("std");

/// 255-byte marker string embedded as PT_INTERP in vowexe. At runtime, vow.zig
/// finds this marker in the embedded binary and patches it with the real
/// dynamic linker path read from the host.
const vow_pt_interp_marker = "!!!VOW_PT_INTERP!!!" ++ ("#" ** (255 - "!!!VOW_PT_INTERP!!!".len));

/// Explicit list of potential shared libraries that vowexe needs at runtime, by their
/// versioned sonames. Adding a new library dependency to vowexe requires adding it here.
/// analyze_vowexe.zig will detect if a new library is linked outside this list.
const allowed_sonames = [_][]const u8{
    "libc.so.6",
    "libxcb.so.1",
    "libvulkan.so.1",
    "libm.so.6",
    "ld-linux-x86-64.so.2",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .linux) @panic("only works on linux targets");

    const vulkan = blk: {
        const exe = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
        const run = b.addRunArtifact(exe);
        const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
        run.addFileArg(registry);
        break :blk b.createModule(.{
            .root_source_file = run.addOutputFileArg("vk.zig"),
        });
    };

    const vkext = b.createModule(.{
        .root_source_file = b.path("vkext/vkext.zig"),
        .imports = &.{
            .{ .name = "vulkan", .module = vulkan },
        },
    });

    const vowproto = b.createModule(.{
        .root_source_file = b.path("vowproto/vowproto.zig"),
        .imports = &.{
            .{ .name = "vkext", .module = vkext },
        },
    });

    const x11 = b.dependency("x11", .{}).module("x11");

    const xcb = b.createModule(.{
        .root_source_file = b.path("xcb/xcb.zig"),
    });

    const shader_compiler = b.dependency("shader_compiler", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }).artifact("shader_compiler");

    const triangle_vert_spv = b.createModule(.{
        .root_source_file = compileShader(b, optimize, shader_compiler, b.path("shaders/triangle.vert"), "triangle.vert.spv"),
    });
    const triangle_frag_spv = b.createModule(.{
        .root_source_file = compileShader(b, optimize, shader_compiler, b.path("shaders/triangle.frag"), "triangle.frag.spv"),
    });

    // vowexe is always built as an explicit cross target (never native) with a
    // poisoned PT_INTERP marker. This ensures the PT_INTERP segment is 255 bytes
    // so any real dynamic linker path can be patched in at runtime.
    const vow_target: std.Build.ResolvedTarget = blk: {
        break :blk b.resolveTargetQuery(.{
            .cpu_arch = switch (target.result.cpu.arch) {
                .x86_64 => .x86_64,
                .aarch64 => .aarch64,
                else => |arch| std.debug.panic("unsupported arch {t}", .{arch}),
            },
            .os_tag = .linux,
            .glibc_version = std.SemanticVersion{ .major = 2, .minor = 1, .patch = 0 },
            .abi = .gnu,
            .dynamic_linker = std.Target.DynamicLinker.init(vow_pt_interp_marker),
        });
    };

    const vow_exe = b.addExecutable(.{
        .name = "vow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vowexe/main.zig"),
            .target = vow_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "xcb", .module = xcb },
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "vkext", .module = vkext },
                .{ .name = "vowproto", .module = vowproto },
            },
        }),
    });
    // Link shared libraries by their versioned .so files directly so the
    // linker records the correct sonames in DT_NEEDED (e.g. libc.so.6,
    // not the linker script libc.so).
    {
        const native_paths = std.zig.system.NativePaths.detect(b.allocator, &b.graph.host.result) catch
            @panic("failed to detect native paths");
        for (allowed_sonames) |soname| {
            const lib_path = findLib(native_paths.lib_dirs.items, soname) orelse
                @panic(b.fmt("could not find {s} in native library paths", .{soname}));
            vow_exe.root_module.addObjectFile(.{ .cwd_relative = lib_path });
        }
    }

    const install_vow_exe = b.addInstallArtifact(vow_exe, .{});
    b.step("install-vow", "").dependOn(&install_vow_exe.step);

    const vowexe_analysis = blk: {
        // Run analyze_vowexe tool to find PT_INTERP offset and verify DT_NEEDED.
        const analyze_vowexe = b.addExecutable(.{
            .name = "analyze_vowexe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("vow/analyze_vowexe.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
            }),
        });
        const run_analyze = b.addRunArtifact(analyze_vowexe);
        run_analyze.addFileArg(vow_exe.getEmittedBin());
        const vowexe_analysis = run_analyze.addOutputFileArg("vowexe_analysis.zig");
        run_analyze.addArg(vow_pt_interp_marker[0..]);
        for (allowed_sonames) |soname| {
            run_analyze.addArg(soname);
        }
        break :blk vowexe_analysis;
    };

    const vow = b.addModule("vow", .{
        .root_source_file = b.path("vow/vow.zig"),
        .imports = &.{
            .{ .name = "vowproto", .module = vowproto },
            // TODO: we should compress vowexe
            .{ .name = "vowexe", .module = b.createModule(.{
                .root_source_file = vow_exe.getEmittedBin(),
            }) },
            .{ .name = "vowexe_analysis", .module = b.createModule(.{
                .root_source_file = vowexe_analysis,
            }) },
        },
    });

    const examples = [_][]const u8{"triangle"};
    for (examples) |example| {
        {
            const exe = b.addExecutable(.{
                .name = b.fmt("{s}-novow", .{example}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("examples/{s}-novow.zig", .{example})),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "xcb", .module = xcb },
                        .{ .name = "vulkan", .module = vulkan },
                        .{ .name = "vkext", .module = vkext },
                        .{ .name = "shaders.triangle.vert", .module = triangle_vert_spv },
                        .{ .name = "shaders.triangle.frag", .module = triangle_frag_spv },
                    },
                    .link_libc = true,
                }),
            });
            exe.linkSystemLibrary("xcb");
            exe.linkSystemLibrary("vulkan");

            const install = b.addInstallArtifact(exe, .{});
            b.step(b.fmt("install-{s}-novow", .{example}), "").dependOn(&install.step);

            const run = b.addRunArtifact(exe);
            run.step.dependOn(&install.step);
            b.step(b.fmt("{s}-novow", .{example}), "").dependOn(&run.step);
        }
        {
            const exe = b.addExecutable(.{
                .name = example,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example})),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "x11", .module = x11 },
                        .{ .name = "vow", .module = vow },
                        .{ .name = "shaders.triangle.vert", .module = triangle_vert_spv },
                        .{ .name = "shaders.triangle.frag", .module = triangle_frag_spv },
                    },
                }),
            });

            const install = b.addInstallArtifact(exe, .{});
            b.step(b.fmt("install-{s}", .{example}), "").dependOn(&install.step);

            const run = b.addRunArtifact(exe);
            run.step.dependOn(&install.step);
            b.step(b.fmt("{s}", .{example}), "").dependOn(&run.step);
        }
    }
}

fn findLib(lib_dirs: []const []const u8, soname: []const u8) ?[]const u8 {
    for (lib_dirs) |dir| {
        const path = std.fs.path.join(std.heap.page_allocator, &.{ dir, soname }) catch @panic("OOM");
        std.fs.cwd().access(path, .{}) catch continue;
        return path;
    }
    return null;
}

fn compileShader(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    shader_compiler: *std.Build.Step.Compile,
    src: std.Build.LazyPath,
    out_basename: []const u8,
) std.Build.LazyPath {
    const compile_shader = b.addRunArtifact(shader_compiler);
    compile_shader.addArgs(&.{
        "--target", "Vulkan-1.3",
    });
    switch (optimize) {
        .Debug => compile_shader.addArgs(&.{
            "--robust-access",
        }),
        .ReleaseSafe => compile_shader.addArgs(&.{
            "--optimize-perf",
            "--robust-access",
        }),
        .ReleaseFast => compile_shader.addArgs(&.{
            "--optimize-perf",
        }),
        .ReleaseSmall => compile_shader.addArgs(&.{
            "--optimize-perf",
            // "--optimize-small",
        }),
    }
    compile_shader.addFileArg(src);
    return compile_shader.addOutputFileArg(out_basename);
}
