// These xcb types are imported by the vulkan module via @import("root")
pub const xcb_connection_t = xcb.Connection;
pub const xcb_visualid_t = xcb.Visual;
pub const xcb_window_t = xcb.Window;

const global = struct {
    var connection: ?*xcb.Connection = null;
    var window: xcb.Window = undefined;
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const gpa = gpa_instance.allocator();
    var maybe_gc: ?GraphicsContext = null;
    var maybe_vert_shader: ?[]const u8 = null;
    var maybe_frag_shader: ?[]const u8 = null;
    var maybe_vertices: ?VertexData = null;
    var maybe_push_constant_ranges: ?[]vk.PushConstantRange = null;
    var clear_color: [4]f32 = .{ 0, 0, 0, 1 };
};

pub fn main() !void {
    var read_buf: [4096]u8 = undefined;
    var reader = std.fs.File.stdin().readerStreaming(&read_buf);
    main2(&reader.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
}
fn main2(reader: *std.Io.Reader) !void {
    defer {
        if (global.maybe_push_constant_ranges) |r| global.gpa.free(r);
        if (global.maybe_vertices) |v| global.gpa.free(v.data);
        if (global.maybe_frag_shader) |s| global.gpa.free(s);
        if (global.maybe_vert_shader) |s| global.gpa.free(s);
        if (global.maybe_gc) |*gc| {
            gc.deinit();
            gc.* = undefined;
        }
    }

    while (true) {
        const request: vowproto.Request = blk: {
            const val = try reader.takeByte();
            break :blk std.enums.fromInt(vowproto.Request, val) orelse std.debug.panic(
                "invalid request {}",
                .{val},
            );
        };
        switch (request) {
            .create_gc => try createGc(reader),
            .vert_shader => try readShader(reader, .vert),
            .frag_shader => try readShader(reader, .frag),
            .vertices => try readVertices(reader),
            .push_constant_ranges => try readPushConstantRanges(reader),
            .clear_color => try reader.readSliceAll(std.mem.asBytes(&global.clear_color)),
            .update => {
                std.log.err("update before placeholder", .{});
                return error.ProtocolError;
            },
            .placeholder => return try placeholder(reader),
        }
    }
}

fn xcbConnect() !*xcb.Connection {
    if (global.connection == null) {
        const display = std.posix.getenv("DISPLAY");
        std.log.info("vow: connecting to X11 DISPLAY {f}", .{xcb.fmtDisplay(display)});
        global.connection, _ = try xcb.connect(display);
    }
    return global.connection.?;
}

fn createGc(reader: *std.Io.Reader) !void {
    const window: xcb.Window = @enumFromInt(try reader.takeInt(u32, native_endian));
    const validation_layers: vowproto.ValidationLayers = blk: {
        const val = try reader.takeByte();
        break :blk std.enums.fromInt(vowproto.ValidationLayers, val) orelse std.debug.panic(
            "invalid validation_layers value {}",
            .{val},
        );
    };
    std.log.info(
        "vow: create_gc window={} validation_layers={t}",
        .{ @intFromEnum(window), validation_layers },
    );
    if (global.maybe_gc != null) {
        std.log.err("gc already created", .{});
        return error.CreateGcTwice;
    }
    global.window = window;
    const connection = try xcbConnect();
    global.maybe_gc = try GraphicsContext.init(global.gpa, "vow", connection, window, .{
        .validation_layers = validation_layers,
    });

    // TODO: maybe add a request to get the device name?
    std.log.info("vow: using device: {s}", .{global.maybe_gc.?.deviceName()});
}
fn readShader(reader: *std.Io.Reader, kind: enum { vert, frag }) !void {
    const shader_ref: *?[]const u8 = switch (kind) {
        .vert => &global.maybe_vert_shader,
        .frag => &global.maybe_frag_shader,
    };
    if (shader_ref.* != null) {
        std.log.err("we've already received a {t} shader", .{kind});
        return error.DuplicateShader;
    }
    const len = try reader.takeInt(usize, native_endian);
    const s = try global.gpa.alloc(u8, len);
    errdefer global.gpa.free(s);
    try reader.readSliceAll(s);
    shader_ref.* = s;
}
fn readVertices(reader: *std.Io.Reader) !void {
    if (global.maybe_vertices != null) {
        std.log.err("vertices already uploaded", .{});
        return error.DuplicateVertices;
    }
    const vertex_count = try reader.takeInt(u32, native_endian);
    const stride = try reader.takeInt(u32, native_endian);
    const num_attributes = try reader.takeByte();
    var attributes: [16]vk.VertexInputAttributeDescription = undefined;
    for (attributes[0..num_attributes]) |*attr| {
        attr.* = .{
            .binding = 0,
            .location = try reader.takeByte(),
            .format = @enumFromInt(try reader.takeInt(u32, native_endian)),
            .offset = try reader.takeInt(u32, native_endian),
        };
    }
    const data_size = @as(usize, vertex_count) * @as(usize, stride);
    const data = try global.gpa.alloc(u8, data_size);
    errdefer global.gpa.free(data);
    try reader.readSliceAll(data);
    global.maybe_vertices = .{
        .vertex_count = vertex_count,
        .stride = stride,
        .num_attributes = num_attributes,
        .attributes = attributes,
        .data = data,
    };
}
fn readPushConstantRanges(reader: *std.Io.Reader) !void {
    const count = try reader.takeByte();
    const ranges = try global.gpa.alloc(vk.PushConstantRange, count);
    errdefer global.gpa.free(ranges);
    try reader.readSliceAll(std.mem.sliceAsBytes(ranges));
    if (global.maybe_push_constant_ranges) |old| global.gpa.free(old);
    global.maybe_push_constant_ranges = ranges;
}
fn placeholder(reader: *std.Io.Reader) !void {
    const map_on_present = try reader.takeByte();
    const gc = &(global.maybe_gc orelse {
        std.log.err("gc not created", .{});
        return error.GcNotCreated;
    });
    const vtx = global.maybe_vertices orelse {
        std.log.err("no vertex data", .{});
        return error.NoVertexData;
    };

    // Query initial extent from the surface
    const caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
    std.log.info("vow: current_extent={}", .{caps.current_extent});
    var extent = caps.current_extent;
    if (extent.width == 0xFFFF_FFFF) {
        extent = .{ .width = 800, .height = 600 };
    }

    var swapchain = try Swapchain.init(gc, global.gpa, extent);
    defer swapchain.deinit();

    const push_constant_ranges = global.maybe_push_constant_ranges orelse &.{};
    const pipeline_layout = try gc.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = @intCast(push_constant_ranges.len),
        .p_push_constant_ranges = push_constant_ranges.ptr,
    }, null);
    defer gc.dev.destroyPipelineLayout(pipeline_layout, null);

    const render_pass = try createRenderPass(gc, swapchain);
    defer gc.dev.destroyRenderPass(render_pass, null);

    const pipeline = try createPipeline(gc, pipeline_layout, render_pass);
    defer gc.dev.destroyPipeline(pipeline, null);

    var framebuffers = try createFramebuffers(gc, global.gpa, render_pass, swapchain);
    defer destroyFramebuffers(gc, global.gpa, framebuffers);

    const pool = try gc.dev.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.dev.destroyCommandPool(pool, null);

    const buffer = try gc.dev.createBuffer(&.{
        .size = vtx.data.len,
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer gc.dev.destroyBuffer(buffer, null);
    const mem_reqs = gc.dev.getBufferMemoryRequirements(buffer);
    const memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
    defer gc.dev.freeMemory(memory, null);
    try gc.dev.bindBufferMemory(buffer, memory, 0);

    try uploadVertices(gc, pool, buffer, vtx.data);

    var cmdbufs = try allocateCommandBuffers(gc, pool, global.gpa, swapchain.swap_images.len);
    defer destroyCommandBuffers(gc, pool, global.gpa, cmdbufs);

    defer {
        swapchain.waitForAllFences() catch {};
        gc.dev.deviceWaitIdle() catch {};
    }

    std.log.info("vow: ready for draw commands", .{});

    var mapped = false;

    // Render loop - driven by draw_frame commands from parent
    while (true) {
        const request: vowproto.Request = blk: {
            const val = reader.takeByte() catch |err| switch (err) {
                error.ReadFailed, error.EndOfStream => return, // parent closed connection
                else => |e| return e,
            };
            break :blk std.enums.fromInt(vowproto.Request, val) orelse std.debug.panic(
                "invalid request in render loop {}",
                .{val},
            );
        };
        switch (request) {
            .update => {
                const pc_len = try reader.takeInt(usize, native_endian);
                if (pc_len > reader.buffer.len) return error.PushConstantsTooLarge;
                const push_constants = try reader.take(pc_len);

                // Wait for this frame's fence before recording its command buffer
                const current_fence = swapchain.swap_images[swapchain.image_index].frame_fence;
                _ = try gc.dev.waitForFences(1, @ptrCast(&current_fence), .true, std.math.maxInt(u64));

                const cmdbuf = cmdbufs[swapchain.image_index];
                try gc.dev.resetCommandBuffer(cmdbuf, .{});
                try recordFrame(gc, cmdbuf, framebuffers[swapchain.image_index], swapchain.extent, render_pass, pipeline, pipeline_layout, buffer, vtx.vertex_count, push_constants);

                const state = swapchain.present(cmdbuf) catch |err| switch (err) {
                    error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
                    else => |narrow| return narrow,
                };

                if (!mapped) {
                    if (map_on_present != 0) {
                        std.log.info("mapping window!", .{});
                        _ = xcb.map_window(global.connection.?, global.window);
                        _ = xcb.flush(global.connection.?);
                    }
                    mapped = true;
                }

                if (state == .suboptimal) {
                    const new_caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
                    extent = new_caps.current_extent;
                    if (extent.width == 0xFFFF_FFFF or extent.width == 0 or extent.height == 0)
                        continue;

                    try gc.dev.deviceWaitIdle();
                    try swapchain.recreate(extent);

                    destroyFramebuffers(gc, global.gpa, framebuffers);
                    framebuffers = try createFramebuffers(gc, global.gpa, render_pass, swapchain);

                    if (cmdbufs.len != swapchain.swap_images.len) {
                        destroyCommandBuffers(gc, pool, global.gpa, cmdbufs);
                        cmdbufs = try allocateCommandBuffers(gc, pool, global.gpa, swapchain.swap_images.len);
                    }
                }
            },
            else => std.debug.panic("unexpected request in render loop: {}", .{@intFromEnum(request)}),
        }
    }
}

fn uploadVertices(gc: *const GraphicsContext, pool: vk.CommandPool, buffer: vk.Buffer, vertex_data: []const u8) !void {
    const staging_buffer = try gc.dev.createBuffer(&.{
        .size = vertex_data.len,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer gc.dev.destroyBuffer(staging_buffer, null);
    const mem_reqs = gc.dev.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.dev.freeMemory(staging_memory, null);
    try gc.dev.bindBufferMemory(staging_buffer, staging_memory, 0);

    {
        const data = try gc.dev.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer gc.dev.unmapMemory(staging_memory);
        const dst: [*]u8 = @ptrCast(data);
        @memcpy(dst[0..vertex_data.len], vertex_data);
    }

    try copyBuffer(gc, pool, buffer, staging_buffer, vertex_data.len);
}

fn copyBuffer(gc: *const GraphicsContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf_handle: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle));
    defer gc.dev.freeCommandBuffers(pool, 1, @ptrCast(&cmdbuf_handle));

    const cmdbuf = GraphicsContext.CommandBuffer.init(cmdbuf_handle, gc.dev.wrapper);
    try cmdbuf.beginCommandBuffer(&.{ .flags = .{ .one_time_submit_bit = true } });
    cmdbuf.copyBuffer(src, dst, 1, @ptrCast(&[_]vk.BufferCopy{.{ .src_offset = 0, .dst_offset = 0, .size = size }}));
    try cmdbuf.endCommandBuffer();

    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&[_]vk.SubmitInfo{.{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
        .p_wait_dst_stage_mask = undefined,
    }}), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

fn allocateCommandBuffers(gc: *const GraphicsContext, pool: vk.CommandPool, gpa: Allocator, count: usize) ![]vk.CommandBuffer {
    const cmdbufs = try gpa.alloc(vk.CommandBuffer, count);
    errdefer gpa.free(cmdbufs);
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);
    return cmdbufs;
}

fn recordFrame(
    gc: *const GraphicsContext,
    cmdbuf: vk.CommandBuffer,
    framebuffer: vk.Framebuffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    buffer: vk.Buffer,
    vertex_count: u32,
    push_constants: []const u8,
) !void {
    try gc.dev.beginCommandBuffer(cmdbuf, &.{});

    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    gc.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
    gc.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    }));

    gc.dev.cmdBeginRenderPass(cmdbuf, &.{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .clear_value_count = 1,
        .p_clear_values = @ptrCast(&vk.ClearValue{ .color = .{ .float_32 = global.clear_color } }),
    }, .@"inline");

    gc.dev.cmdBindPipeline(cmdbuf, .graphics, pipeline);
    if (push_constants.len > 0) {
        gc.dev.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true }, 0, @intCast(push_constants.len), push_constants.ptr);
    }
    gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&buffer), &[_]vk.DeviceSize{0});
    gc.dev.cmdDraw(cmdbuf, vertex_count, 1, 0, 0);

    gc.dev.cmdEndRenderPass(cmdbuf);
    try gc.dev.endCommandBuffer(cmdbuf);
}

fn destroyCommandBuffers(gc: *const GraphicsContext, pool: vk.CommandPool, gpa: Allocator, cmdbufs: []vk.CommandBuffer) void {
    gc.dev.freeCommandBuffers(pool, @truncate(cmdbufs.len), cmdbufs.ptr);
    gpa.free(cmdbufs);
}

fn createFramebuffers(gc: *const GraphicsContext, gpa: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain) ![]vk.Framebuffer {
    const framebuffers = try gpa.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer gpa.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| gc.dev.destroyFramebuffer(fb, null);

    for (framebuffers) |*fb| {
        fb.* = try gc.dev.createFramebuffer(&.{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&swapchain.swap_images[i].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(gc: *const GraphicsContext, gpa: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| gc.dev.destroyFramebuffer(fb, null);
    gpa.free(framebuffers);
}

fn createRenderPass(gc: *const GraphicsContext, swapchain: Swapchain) !vk.RenderPass {
    const color_attachment: vk.AttachmentDescription = .{
        .format = swapchain.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const color_attachment_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
    };
    return try gc.dev.createRenderPass(&.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
}

fn createPipeline(gc: *const GraphicsContext, layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
    const vert_shader = global.maybe_vert_shader orelse {
        std.log.err("no vertex shader", .{});
        return error.NoVertexShader;
    };
    const frag_shader = global.maybe_frag_shader orelse {
        std.log.err("no fragment shader", .{});
        return error.NoFragmentShader;
    };
    const vtx = global.maybe_vertices orelse {
        std.log.err("no vertex data", .{});
        return error.NoVertexData;
    };

    const vert = try gc.dev.createShaderModule(&.{
        .code_size = vert_shader.len,
        .p_code = @ptrCast(@alignCast(vert_shader.ptr)),
    }, null);
    defer gc.dev.destroyShaderModule(vert, null);

    const frag = try gc.dev.createShaderModule(&.{
        .code_size = frag_shader.len,
        .p_code = @ptrCast(@alignCast(frag_shader.ptr)),
    }, null);
    defer gc.dev.destroyShaderModule(frag, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = frag, .p_name = "main" },
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &.{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&vk.VertexInputBindingDescription{
                .binding = 0,
                .stride = vtx.stride,
                .input_rate = .vertex,
            }),
            .vertex_attribute_description_count = vtx.num_attributes,
            .p_vertex_attribute_descriptions = vtx.attributes[0..vtx.num_attributes].ptr,
        },
        .p_input_assembly_state = &.{ .topology = .triangle_list, .primitive_restart_enable = .false },
        .p_tessellation_state = null,
        .p_viewport_state = &.{
            .viewport_count = 1,
            .p_viewports = undefined,
            .scissor_count = 1,
            .p_scissors = undefined,
        },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = null,
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&vk.PipelineColorBlendAttachmentState{
                .blend_enable = .false,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            }),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{
            .flags = .{},
            .dynamic_state_count = 2,
            .p_dynamic_states = &[_]vk.DynamicState{ .viewport, .scissor },
        },
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.dev.createGraphicsPipelines(.null_handle, 1, @ptrCast(&gpci), null, @ptrCast(&pipeline));
    return pipeline;
}

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const vowproto = @import("vowproto");

const xcb = @import("xcb");
const vk = @import("vulkan");

const vkext = @import("vkext");
const GraphicsContext = vkext.GraphicsContext;
const Swapchain = vkext.Swapchain;

const VertexData = struct {
    vertex_count: u32,
    stride: u32,
    num_attributes: u32,
    attributes: [16]vk.VertexInputAttributeDescription,
    data: []u8,
};

const native_endian = builtin.cpu.arch.endian();
