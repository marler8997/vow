const builtin = @import("builtin");
const std = @import("std");

/// 255-byte marker string embedded as PT_INTERP in vowexe. At runtime, vow.zig
/// finds this marker in the embedded binary and patches it with the real
/// dynamic linker path read from the host.
const vow_pt_interp_marker = "!!!VOW_PT_INTERP!!!" ++ ("#" ** (255 - "!!!VOW_PT_INTERP!!!".len));

/// 255-byte marker string embedded as the libc DT_NEEDED soname in vowexe.
/// At runtime, vow.zig patches it with the real libc soname (e.g. "libc.so.6"
/// on glibc, "libc.musl-x86_64.so.1" on musl).
const vow_dt_needed_libc_marker = "!!!VOW_DT_NEEDED_LIBC!!!" ++ ("#" ** (255 - "!!!VOW_DT_NEEDED_LIBC!!!".len));

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

    const xcb = b.createModule(.{
        .root_source_file = b.path("xcb/xcb.zig"),
    });
    const solazy = b.dependency("solazy", .{}).module("solazy");

    const vowproto = b.createModule(.{
        .root_source_file = b.path("vowproto/vowproto.zig"),
        .imports = &.{
            .{ .name = "vulkan", .module = vulkan },
        },
    });

    const x11 = b.dependency("x11", .{}).module("x11");
    const wl = b.dependency("wayland", .{}).module("wl");

    const shader_compiler = b.dependency("shader_compiler", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }).artifact("shader_compiler");

    const triangle_vert_spv = b.createModule(.{
        .root_source_file = compileShader(b, optimize, shader_compiler, b.path("example/shader.vert"), "triangle.vert.spv"),
    });
    const triangle_frag_spv = b.createModule(.{
        .root_source_file = compileShader(b, optimize, shader_compiler, b.path("example/shader.frag"), "triangle.frag.spv"),
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
            .abi = .none,
            .dynamic_linker = std.Target.DynamicLinker.init(vow_pt_interp_marker),
        });
    };

    // Generate a stub shared library with the marker as SONAME.
    // This provides dlopen/dlsym/dlclose/dlerror symbols at link time.
    // At runtime, the marker gets patched to the real libc soname.
    const libc_stub_so = blk: {
        const gen_stub = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-shared" });
        gen_stub.addArg("-Wl,-soname," ++ vow_dt_needed_libc_marker);
        gen_stub.addArgs(&.{ "-x", "c", "-target" });
        gen_stub.addArg(switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-linux-gnu",
            .aarch64 => "aarch64-linux-gnu",
            else => unreachable,
        });
        gen_stub.addArg("-o");
        const stub_so = gen_stub.addOutputFileArg("libvow_dlstub.so");
        gen_stub.addFileArg(b.path("vow/dlstub.c"));
        break :blk stub_so;
    };

    const vow_exe = b.addExecutable(.{
        .name = "vow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vowexe/main.zig"),
            .target = vow_target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "solazy", .module = solazy },
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "vowproto", .module = vowproto },
                .{ .name = "xcb", .module = xcb },
            },
        }),
    });
    // Link the stub .so to resolve dlopen/dlsym/dlclose/dlerror.
    // The stub's SONAME (the marker) becomes the DT_NEEDED entry,
    // which vow.zig patches to the real libc soname at runtime.
    vow_exe.root_module.addObjectFile(libc_stub_so);

    const install_vow_exe = b.addInstallArtifact(vow_exe, .{});
    b.step("install-vow", "").dependOn(&install_vow_exe.step);

    const vowexe_analysis = blk: {
        // Run analyze_vowexe tool to find PT_INTERP offset, DT_NEEDED libc
        // marker offset, and verify no unexpected DT_NEEDED entries.
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
        run_analyze.addArg(vow_dt_needed_libc_marker[0..]);
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

    {
        const exe = b.addExecutable(.{
            .name = "example",
            .root_module = b.createModule(.{
                .root_source_file = b.path("example/example.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "x11", .module = x11 },
                    .{ .name = "wl", .module = wl },
                    .{ .name = "vow", .module = vow },
                    .{ .name = "shaders.triangle.vert", .module = triangle_vert_spv },
                    .{ .name = "shaders.triangle.frag", .module = triangle_frag_spv },
                },
            }),
        });

        const install = b.addInstallArtifact(exe, .{});
        b.step("install-example", "").dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        b.step("example", "").dependOn(&run.step);
    }
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
        .Debug => {},
        .ReleaseSafe => compile_shader.addArgs(&.{
            "--optimize-perf",
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
