const vk_lib = "libvulkan.so.1";
const lib_store = solazy.LibStorage(vk_lib);

pub const vkGetInstanceProcAddr = lazy.vkGetInstanceProcAddr;

pub fn init() !void {
    std.debug.assert(lib_store.global_handle.load(.acquire) == null);
    var found: bool = false;
    if (try dlopen(&found, vk_lib)) return;
    if (try dlopen(&found, "/run/current-system/sw/lib/libvulkan.so.1")) return;
    if (try dlopen(&found, "/run/opengl-driver/lib/libvulkan.so.1")) return;
    if (try nixStore(&found)) return;
    const desc: []const u8 = if (found) "load" else "locate";
    std.debug.panic("failed to {s} libvulkan.so.1", .{desc});
}

fn dlopen(found_ref: *bool, path: [:0]const u8) !bool {
    if (solazy.os.dlopen(path, .{ .LAZY = true })) |handle| {
        lib_store.global_handle.store(handle, .release);
        std.log.info("vulkan-loader: '{s}'", .{path});
        return true;
    }
    const is_file_path = std.mem.indexOfScalar(u8, path, '/') != null;
    if (is_file_path) {
        if (std.fs.cwd().access(path, .{})) {
            found_ref.* = true;
            std.log.info("dlopen '{s}' failed (even though it exists)", .{path});
        } else |err| switch (err) {
            error.FileNotFound => {
                std.log.info("dlopen '{s}' failed (does not exist)", .{path});
            },
            else => |e| return e,
        }
    } else {
        std.log.info("dlopen '{s}' failed", .{path});
    }
    return false;
}

fn nixStore(found_ref: *bool) !bool {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const result = std.process.Child.run(.{
        .allocator = arena_instance.allocator(),
        .argv = &.{ "nix-store", "-qR", "/run/current-system" },
        .max_output_bytes = 800 * 10_000,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("nix-store not found in PATH", .{});
            return false;
        },
        else => |e| return e,
    };
    try std.fs.File.stderr().writeAll(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.info("nix-store failed with exit code {}", .{code});
                return false;
            }
        },
        inline else => |sig, why| {
            std.log.err("nix-store failed ({t}) with signal {}", .{ why, sig });
            return false;
        },
    }
    var line_it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const prefix = "/nix/store/";
        const hash_len = 32;
        std.debug.assert(std.mem.startsWith(u8, line, prefix));
        std.debug.assert(line.len > prefix.len + hash_len + 1);
        const pkg = line[prefix.len + hash_len + 1 ..];
        std.debug.assert(pkg.len > 0);
        if (!std.mem.startsWith(u8, pkg, "vulkan-loader-")) continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/lib/" ++ vk_lib, .{line});
        if (try dlopen(found_ref, path)) return true;
    }
    return false;
}

const lazy = solazy.namespace(.panic, &.{
    .{ .lib = vk_lib, .name = "vkGetInstanceProcAddr", .Fn = fn (vk.Instance, [*:0]const u8) callconv(.c) vk.PfnVoidFunction },
});

const std = @import("std");
const vk = @import("vulkan");
const solazy = @import("solazy");
