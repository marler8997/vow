pub const vkGetInstanceProcAddr = lazy.vkGetInstanceProcAddr;

const vk_lib = "libvulkan.so.1";
const lazy = solazy.namespace(.panic, &.{
    .{ .lib = vk_lib, .name = "vkGetInstanceProcAddr", .Fn = fn (vk.Instance, [*:0]const u8) callconv(.c) vk.PfnVoidFunction },
});

const std = @import("std");
const vk = @import("vulkan");
const solazy = @import("solazy");
