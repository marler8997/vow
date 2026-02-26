pub const Request = enum(u8) {
    create_gc = 0,
    vert_shader = 1,
    frag_shader = 2,
    raster_desc = 3,
    clear_color = 5,
    begin = 7,
    draw = 8,
    begin_render_pass = 9,
    end_render_pass = 10,
    present = 11,
    gpu_malloc = 12,
    gpu_upload = 13,
    gpu_free = 14,
    bind_pipeline = 15,
    create_device = 16,
    create_render_targets = 17,
    submit = 18,
};

pub const ValidationLayers = enum(u8) {
    no = 0,
    if_available = 1,
    require = 2,

    pub const default = if (builtin.mode == .Debug) .if_available else .no;
};

pub const RenderTargetTransport = enum(u8) { dmabuf, shm };

/// Metadata sent alongside each render target fd via SCM_RIGHTS
pub const RenderTargetInfo = extern struct {
    transport: RenderTargetTransport,
    _pad: [3]u8 = .{0} ** 3,
    stride: u32,
    offset: u32,
    size: u64,
    format: u32, // DRM fourcc
    modifier: u64,
};

pub const RasterDesc = extern struct {
    topology: Topology = .triangle_list,
    polygon_mode: PolygonMode = .fill,
    cull_mode: CullMode = .back,
    front_face: FrontFace = .clockwise,
    sample_count: SampleCount = .@"1",
    blend_enable: u8 = 0,
    src_color_blend_factor: BlendFactor = .one,
    dst_color_blend_factor: BlendFactor = .zero,
    color_blend_op: BlendOp = .add,
    src_alpha_blend_factor: BlendFactor = .one,
    dst_alpha_blend_factor: BlendFactor = .zero,
    alpha_blend_op: BlendOp = .add,

    comptime {
        std.debug.assert(@sizeOf(RasterDesc) == 12);
    }
};

pub const Topology = enum(u8) {
    triangle_list,
    triangle_strip,
    line_list,
    line_strip,
    point_list,

    pub fn toVulkan(self: Topology) vk.PrimitiveTopology {
        return switch (self) {
            .triangle_list => .triangle_list,
            .triangle_strip => .triangle_strip,
            .line_list => .line_list,
            .line_strip => .line_strip,
            .point_list => .point_list,
        };
    }
};

pub const PolygonMode = enum(u8) {
    fill,
    line,
    point,

    pub fn toVulkan(self: PolygonMode) vk.PolygonMode {
        return switch (self) {
            .fill => .fill,
            .line => .line,
            .point => .point,
        };
    }
};

pub const CullMode = enum(u8) {
    none,
    front,
    back,
    front_and_back,

    pub fn toVulkan(self: CullMode) vk.CullModeFlags {
        return switch (self) {
            .none => .{},
            .front => .{ .front_bit = true },
            .back => .{ .back_bit = true },
            .front_and_back => .{ .front_bit = true, .back_bit = true },
        };
    }
};

pub const FrontFace = enum(u8) {
    clockwise,
    counter_clockwise,

    pub fn toVulkan(self: FrontFace) vk.FrontFace {
        return switch (self) {
            .clockwise => .clockwise,
            .counter_clockwise => .counter_clockwise,
        };
    }
};

pub const SampleCount = enum(u8) {
    @"1",
    @"2",
    @"4",
    @"8",

    pub fn toVulkan(self: SampleCount) vk.SampleCountFlags {
        return switch (self) {
            .@"1" => .{ .@"1_bit" = true },
            .@"2" => .{ .@"2_bit" = true },
            .@"4" => .{ .@"4_bit" = true },
            .@"8" => .{ .@"8_bit" = true },
        };
    }
};

pub const BlendFactor = enum(u8) {
    zero,
    one,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,

    pub fn toVulkan(self: BlendFactor) vk.BlendFactor {
        return switch (self) {
            .zero => .zero,
            .one => .one,
            .src_alpha => .src_alpha,
            .one_minus_src_alpha => .one_minus_src_alpha,
            .dst_alpha => .dst_alpha,
            .one_minus_dst_alpha => .one_minus_dst_alpha,
        };
    }
};

pub const BlendOp = enum(u8) {
    add,
    subtract,
    reverse_subtract,
    min,
    max,

    pub fn toVulkan(self: BlendOp) vk.BlendOp {
        return switch (self) {
            .add => .add,
            .subtract => .subtract,
            .reverse_subtract => .reverse_subtract,
            .min => .min,
            .max => .max,
        };
    }
};

const builtin = @import("builtin");
const std = @import("std");
const vk = @import("vulkan");
