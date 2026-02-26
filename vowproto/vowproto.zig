pub const vkext = @import("vkext");

pub const Request = enum(u8) {
    create_gc = 0,
    vert_shader = 1,
    frag_shader = 2,
    vertices = 4,
    update = 5,
    push_constant_ranges = 6,
    clear_color = 7,
    placeholder = 8,
};

pub const ValidationLayers = vkext.GraphicsContext.ValidationLayers;

pub const ShaderStage = struct {
    pub const vertex: u32 = 0x00000001;
    pub const fragment: u32 = 0x00000010;
    pub const all_graphics: u32 = 0x0000001F;
};
pub const PushConstantRange = extern struct {
    stage_flags: u32,
    offset: u32,
    size: u32,
};

pub const Format = enum(u32) {
    r32_sfloat = 100,
    r32g32_sfloat = 103,
    r32g32b32_sfloat = 106,
    r32g32b32a32_sfloat = 109,
    _,
};

pub const VertexAttribute = struct {
    location: u8,
    format: Format,
    offset: u32,
};

const std = @import("std");
