// These xcb types are imported by the vulkan module via @import("root")
pub const xcb_connection_t = xcb.Connection;
pub const xcb_visualid_t = xcb.Visual;
pub const xcb_window_t = xcb.Window;

const SharedMem = struct {
    fd: std.posix.fd_t,
    size: usize = 0,
    /// CPU-side mmap of the shared memfd (read-only, for copying to GPU buffer)
    mapped: ?[]align(std.heap.page_size_min) u8 = null,
    /// GPU-side host-visible buffer with device address support
    gpu_buffer: ?vk.Buffer = null,
    gpu_memory: ?vk.DeviceMemory = null,
    gpu_mapped: ?[*]u8 = null,
    device_address: ?vk.DeviceAddress = null,

    fn deinit(self: *SharedMem, gc: ?*const GraphicsContext) void {
        if (self.gpu_mapped != null) {
            gc.?.dev.unmapMemory(self.gpu_memory.?);
        }
        if (self.gpu_buffer) |buf| {
            gc.?.dev.destroyBuffer(buf, null);
        }
        if (self.gpu_memory) |mem| {
            gc.?.dev.freeMemory(mem, null);
        }
        if (self.mapped) |m| {
            std.posix.munmap(m);
        }
        self.* = undefined;
    }
};

const RenderTarget = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    framebuffer: vk.Framebuffer,
    width: u32,
    height: u32,
    transport: union(enum) {
        dmabuf: struct { fd: std.posix.fd_t },
        shm: struct { host_buffer: vk.Buffer, host_memory: vk.DeviceMemory, memfd: std.posix.fd_t },
    },
};

const global = struct {
    var shared_mems: []SharedMem = &.{};
    var xcb_funcs: ?xcb.Funcs = null;
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const gpa = gpa_instance.allocator();
    var maybe_gc: ?GraphicsContext = null;
    var maybe_vert_shader: ?[]const u8 = null;
    var maybe_frag_shader: ?[]const u8 = null;
    var clear_color: [4]f32 = .{ 0, 0, 0, 1 };
    var raster_descs: [256]vowproto.RasterDesc = undefined;
    var num_raster_descs: u8 = 0;
    var mode: enum { swapchain, dmabuf } = .swapchain;
    var render_targets: [8]RenderTarget = undefined;
    var dmabuf_count: u8 = 0;
    var dmabuf_render_pass: vk.RenderPass = .null_handle;
    var dmabuf_extent: vk.Extent2D = .{ .width = 0, .height = 0 };
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
        if (global.maybe_frag_shader) |s| global.gpa.free(s);
        if (global.maybe_vert_shader) |s| global.gpa.free(s);
        if (global.maybe_gc) |*gc| {
            for (global.shared_mems) |*s| s.deinit(gc);
            gc.deinit();
            gc.* = undefined;
        } else {
            for (global.shared_mems) |*s| s.deinit(null);
        }
        global.gpa.free(global.shared_mems);
    }

    try vklazy.init();

    // Read shared buffer preamble: usize count + i32[] fd values
    {
        const count = try reader.takeInt(usize, native_endian);
        std.log.info("vow: {} shared memfd(s)", .{count});
        if (count > 0) {
            global.shared_mems = try global.gpa.alloc(SharedMem, count);
            for (global.shared_mems) |*s| {
                s.* = .{ .fd = try reader.takeInt(i32, native_endian) };
            }
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
            .create_device => try createDevice(reader),
            .create_render_targets => try createRenderTargets(reader),
            .vert_shader => try readShader(reader, .vert),
            .frag_shader => try readShader(reader, .frag),
            .raster_desc => {
                var desc: vowproto.RasterDesc = undefined;
                try reader.readSliceAll(std.mem.asBytes(&desc));
                if (global.num_raster_descs >= 256) {
                    std.log.err("too many raster descs (max 256)", .{});
                    return error.TooManyRasterDescs;
                }
                global.raster_descs[global.num_raster_descs] = desc;
                global.num_raster_descs += 1;
            },
            .clear_color => try reader.readSliceAll(std.mem.asBytes(&global.clear_color)),
            .begin => return try begin(reader),
            .draw, .begin_render_pass, .end_render_pass, .present, .submit, .gpu_malloc, .gpu_upload, .gpu_free, .bind_pipeline => {
                std.log.err("{t} before begin", .{request});
                return error.ProtocolError;
            },
        }
    }
}

fn xcbConnect() !*xcb.Connection {
    if (global.connection == null) {
        const display = std.posix.getenv("DISPLAY");
        std.log.info("vow: connecting to X11 DISPLAY {f}", .{xcb.fmtDisplay(display)});
        global.connection, _ = try xcb.connect(display);
    }
    return global.maybe_gc.?.xcb_connection;
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
    global.maybe_gc = try GraphicsContext.init(global.gpa, "vow", .{ .xcb = window }, vklazy.vkGetInstanceProcAddr, .{
        .validation_layers = validation_layers,
    });

    // TODO: maybe add a request to get the device name?
    std.log.info("vow: using device: {s}", .{global.maybe_gc.?.deviceName()});
}
fn createDevice(reader: *std.Io.Reader) !void {
    const validation_layers: vowproto.ValidationLayers = blk: {
        const val = try reader.takeByte();
        break :blk std.enums.fromInt(vowproto.ValidationLayers, val) orelse std.debug.panic(
            "invalid validation_layers value {}",
            .{val},
        );
    };
    std.log.info("vow: create_device validation_layers={t}", .{validation_layers});
    if (global.maybe_gc != null) {
        std.log.err("gc already created", .{});
        return error.CreateGcTwice;
    }
    global.mode = .dmabuf;
    global.maybe_gc = try GraphicsContext.init(global.gpa, "vow", .headless, vklazy.vkGetInstanceProcAddr, .{
        .validation_layers = validation_layers,
    });
    std.log.info("vow: using device: {s}", .{global.maybe_gc.?.deviceName()});
}

fn createRenderTargets(reader: *std.Io.Reader) !void {
    const width = try reader.takeInt(u32, native_endian);
    const height = try reader.takeInt(u32, native_endian);
    const count = try reader.takeByte();
    std.log.info("vow: create_render_targets {}x{} count={}", .{ width, height, count });

    if (count == 0 or count > global.render_targets.len) {
        std.log.err("invalid render target count {}", .{count});
        return error.InvalidCount;
    }

    const gc = &(global.maybe_gc orelse {
        std.log.err("gc not created", .{});
        return error.GcNotCreated;
    });

    // Create render pass for dmabuf targets
    const color_attachment: vk.AttachmentDescription = .{
        .format = .b8g8r8a8_unorm,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .general,
    };
    const color_attachment_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
    };
    global.dmabuf_render_pass = try gc.dev.createRenderPass(&.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);

    global.dmabuf_extent = .{ .width = width, .height = height };

    const stride = width * 4; // B8G8R8A8 = 4 bytes per pixel
    const buf_size: usize = @as(usize, stride) * @as(usize, height);
    const page_size = std.heap.page_size_min;
    const aligned_size: usize = (buf_size + page_size - 1) & ~(page_size - 1);

    // stdout fd (socket to parent) for sending fds via SCM_RIGHTS
    const stdout_fd: std.posix.fd_t = 0; // stdin is actually the socket (dup2'd in exec)

    const use_dmabuf = gc.has_dmabuf_export;
    if (use_dmabuf) {
        std.log.info("vow: using DMA-BUF export (zero copy)", .{});
    } else {
        std.log.info("vow: using SHM fallback (host pointer copy)", .{});
    }

    for (0..count) |i| {
        var image: vk.Image = undefined;
        var img_memory: vk.DeviceMemory = undefined;
        var transport: @FieldType(RenderTarget, "transport") = undefined;
        var info: vowproto.RenderTargetInfo = undefined;
        var send_fd: std.posix.fd_t = undefined;

        if (use_dmabuf) {
            // DMA-BUF path: create linear-tiled image with external memory, export as fd
            const modifier_list: vk.ImageDrmFormatModifierListCreateInfoEXT = .{
                .drm_format_modifier_count = 1,
                .p_drm_format_modifiers = &[_]u64{0}, // DRM_FORMAT_MOD_LINEAR
            };
            const ext_mem_info: vk.ExternalMemoryImageCreateInfo = .{
                .p_next = @ptrCast(&modifier_list),
                .handle_types = .{ .dma_buf_bit_ext = true },
            };
            image = try gc.dev.createImage(&.{
                .p_next = @ptrCast(&ext_mem_info),
                .image_type = .@"2d",
                .format = .b8g8r8a8_unorm,
                .extent = .{ .width = width, .height = height, .depth = 1 },
                .mip_levels = 1,
                .array_layers = 1,
                .samples = .{ .@"1_bit" = true },
                .tiling = .drm_format_modifier_ext,
                .usage = .{ .color_attachment_bit = true },
                .sharing_mode = .exclusive,
                .initial_layout = .undefined,
            }, null);

            const img_mem_reqs = gc.dev.getImageMemoryRequirements(image);

            const export_info: vk.ExportMemoryAllocateInfo = .{
                .handle_types = .{ .dma_buf_bit_ext = true },
            };
            const img_mem_type = gc.findMemoryTypeIndex(img_mem_reqs.memory_type_bits, .{
                .device_local_bit = true,
            }) catch try gc.findMemoryTypeIndex(img_mem_reqs.memory_type_bits, .{});
            img_memory = try gc.dev.allocateMemory(&.{
                .allocation_size = img_mem_reqs.size,
                .memory_type_index = img_mem_type,
                .p_next = @ptrCast(&export_info),
            }, null);
            try gc.dev.bindImageMemory(image, img_memory, 0);

            // Export as DMA-BUF fd
            const dmabuf_fd = try gc.dev.getMemoryFdKHR(&.{
                .memory = img_memory,
                .handle_type = .{ .dma_buf_bit_ext = true },
            });

            // Query actual modifier applied
            var modifier_props: vk.ImageDrmFormatModifierPropertiesEXT = undefined;
            try gc.dev.getImageDrmFormatModifierPropertiesEXT(image, &modifier_props);

            transport = .{ .dmabuf = .{ .fd = dmabuf_fd } };
            send_fd = dmabuf_fd;
            info = .{
                .transport = .dmabuf,
                .stride = stride,
                .offset = 0,
                .size = img_mem_reqs.size,
                .format = 0x34324241, // DRM_FORMAT_ARGB8888
                .modifier = modifier_props.drm_format_modifier,
            };

            std.log.info("vow: render target {} dmabuf fd={} modifier={} size={}", .{
                i, dmabuf_fd, modifier_props.drm_format_modifier, img_mem_reqs.size,
            });
        } else {
            // SHM fallback: optimal image + host-pointer-backed buffer
            image = try gc.dev.createImage(&.{
                .image_type = .@"2d",
                .format = .b8g8r8a8_unorm,
                .extent = .{ .width = width, .height = height, .depth = 1 },
                .mip_levels = 1,
                .array_layers = 1,
                .samples = .{ .@"1_bit" = true },
                .tiling = .optimal,
                .usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
                .sharing_mode = .exclusive,
                .initial_layout = .undefined,
            }, null);

            const img_mem_reqs = gc.dev.getImageMemoryRequirements(image);
            const img_mem_type = gc.findMemoryTypeIndex(img_mem_reqs.memory_type_bits, .{
                .device_local_bit = true,
            }) catch try gc.findMemoryTypeIndex(img_mem_reqs.memory_type_bits, .{});
            img_memory = try gc.dev.allocateMemory(&.{
                .allocation_size = img_mem_reqs.size,
                .memory_type_index = img_mem_type,
            }, null);
            try gc.dev.bindImageMemory(image, img_memory, 0);

            // Create memfd and mmap for host-backed readback buffer
            const memfd = try std.posix.memfd_createZ("vow-render-target", 0);
            try std.posix.ftruncate(memfd, @intCast(aligned_size));
            const mapped = try std.posix.mmap(null, aligned_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, memfd, 0);
            const host_ptr: *anyopaque = @ptrCast(mapped.ptr);

            var host_props: vk.MemoryHostPointerPropertiesEXT = undefined;
            try gc.dev.getMemoryHostPointerPropertiesEXT(.{ .host_allocation_bit_ext = true }, host_ptr, &host_props);

            const host_buffer = try gc.dev.createBuffer(&.{
                .size = aligned_size,
                .usage = .{ .transfer_dst_bit = true },
                .sharing_mode = .exclusive,
            }, null);

            const buf_mem_reqs = gc.dev.getBufferMemoryRequirements(host_buffer);

            const import_info: vk.ImportMemoryHostPointerInfoEXT = .{
                .handle_type = .{ .host_allocation_bit_ext = true },
                .p_host_pointer = host_ptr,
            };

            const compatible_bits = buf_mem_reqs.memory_type_bits & host_props.memory_type_bits;
            const buf_mem_type = gc.findMemoryTypeIndex(compatible_bits, .{}) catch {
                std.log.err("no memory type compatible with both buffer and host pointer (buffer=0b{b:0>32} host=0b{b:0>32})", .{
                    buf_mem_reqs.memory_type_bits, host_props.memory_type_bits,
                });
                return error.NoCompatibleMemoryType;
            };

            const host_memory = try gc.dev.allocateMemory(&.{
                .allocation_size = aligned_size,
                .memory_type_index = buf_mem_type,
                .p_next = @ptrCast(&import_info),
            }, null);
            try gc.dev.bindBufferMemory(host_buffer, host_memory, 0);

            transport = .{ .shm = .{ .host_buffer = host_buffer, .host_memory = host_memory, .memfd = memfd } };
            send_fd = memfd;
            info = .{
                .transport = .shm,
                .stride = stride,
                .offset = 0,
                .size = aligned_size,
                .format = 0, // wl_shm format argb8888
                .modifier = 0,
            };

            std.log.info("vow: render target {} memfd={} stride={} size={}", .{
                i, memfd, stride, aligned_size,
            });
        }

        // Create image view
        const view = try gc.dev.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = .b8g8r8a8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        // Create framebuffer
        const framebuffer = try gc.dev.createFramebuffer(&.{
            .render_pass = global.dmabuf_render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&view),
            .width = width,
            .height = height,
            .layers = 1,
        }, null);

        global.render_targets[i] = .{
            .image = image,
            .memory = img_memory,
            .view = view,
            .framebuffer = framebuffer,
            .width = width,
            .height = height,
            .transport = transport,
        };

        // Send fd + metadata back to parent via SCM_RIGHTS
        var info_bytes: [@sizeOf(vowproto.RenderTargetInfo)]u8 = undefined;
        @memcpy(&info_bytes, std.mem.asBytes(&info));
        const iov = [_]std.posix.iovec_const{
            .{ .base = &info_bytes, .len = info_bytes.len },
        };
        const cmsg: Cmsg(std.posix.fd_t) = .{
            .level = std.posix.SOL.SOCKET,
            .type = 1, // SCM_RIGHTS
            .data = send_fd,
        };
        const send_msg: std.posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg,
            .controllen = cmsg.len,
            .flags = 0,
        };
        const sent = std.posix.sendmsg(stdout_fd, &send_msg, 0) catch |e| {
            std.log.err("sendmsg failed: {}", .{e});
            return error.SendFailed;
        };
        if (sent != info_bytes.len) {
            std.log.err("sendmsg: expected to send {} bytes but sent {}", .{ info_bytes.len, sent });
            return error.SendFailed;
        }
    }

    global.dmabuf_count = count;
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
fn importSharedMem(gc: *const GraphicsContext, sm: *SharedMem, i: usize) !void {
    const stat = try std.posix.fstat(sm.fd);
    const size: u64 = @intCast(stat.size);
    const len: usize = @intCast(size);

    std.log.info("vow: importing shared mem {} fd={} size={}", .{ i, sm.fd, size });

    // mmap the shared memfd for CPU-side reads
    const mapped = try std.posix.mmap(null, len, std.posix.PROT.READ, .{ .TYPE = .SHARED }, sm.fd, 0);
    errdefer std.posix.munmap(mapped);

    // Create a host-visible Vulkan buffer with device address support.
    // We can't use VK_EXT_external_memory_host with device addresses (driver limitation),
    // so we create a separate GPU buffer and memcpy from shared mem each frame.
    const gpu_buffer = gc.dev.createBuffer(&.{
        .size = size,
        .usage = .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch |err| {
        std.log.err("createBuffer for shared mem {} failed: {}", .{ i, err });
        return error.VulkanImportFailed;
    };
    errdefer gc.dev.destroyBuffer(gpu_buffer, null);

    const mem_reqs = gc.dev.getBufferMemoryRequirements(gpu_buffer);

    const memory_type_index = gc.findMemoryTypeIndex(mem_reqs.memory_type_bits, .{
        .host_visible_bit = true,
        .host_coherent_bit = true,
    }) catch |err| {
        std.log.err("no suitable memory type for shared mem {}: {}", .{ i, err });
        return error.VulkanImportFailed;
    };

    const alloc_flags_info: vk.MemoryAllocateFlagsInfo = .{
        .flags = .{ .device_address_bit = true },
        .device_mask = 0,
    };

    const gpu_memory = gc.dev.allocateMemory(&.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = memory_type_index,
        .p_next = @ptrCast(&alloc_flags_info),
    }, null) catch |err| {
        std.log.err("allocateMemory for shared mem {} failed: {}", .{ i, err });
        return error.VulkanImportFailed;
    };
    errdefer gc.dev.freeMemory(gpu_memory, null);

    try gc.dev.bindBufferMemory(gpu_buffer, gpu_memory, 0);

    const gpu_mapped_raw = try gc.dev.mapMemory(gpu_memory, 0, vk.WHOLE_SIZE, .{});
    const gpu_mapped: [*]u8 = @ptrCast(gpu_mapped_raw);

    const device_address = gc.dev.getBufferDeviceAddress(&.{
        .buffer = gpu_buffer,
    });

    sm.size = len;
    sm.mapped = mapped;
    sm.gpu_buffer = gpu_buffer;
    sm.gpu_memory = gpu_memory;
    sm.gpu_mapped = gpu_mapped;
    sm.device_address = device_address;

    std.log.info("vow: shared mem {} imported successfully, device_address=0x{x}", .{ i, device_address });
}

fn begin(reader: *std.Io.Reader) !void {
    const map_on_present = try reader.takeByte();
    const gc = &(global.maybe_gc orelse {
        std.log.err("gc not created", .{});
        return error.GcNotCreated;
    });

    // Two push constants: vertex data pointer + pixel data pointer
    const push_constant_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf([2]u64),
    };
    const pipeline_layout = try gc.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_constant_range),
    }, null);
    defer gc.dev.destroyPipelineLayout(pipeline_layout, null);

    // If no raster descs were sent, use a single default
    if (global.num_raster_descs == 0) {
        global.raster_descs[0] = .{};
        global.num_raster_descs = 1;
    }

    switch (global.mode) {
        .swapchain => try beginSwapchain(reader, gc, pipeline_layout, map_on_present),
        .dmabuf => try beginDmabuf(reader, gc, pipeline_layout),
    }
}

fn beginDmabuf(reader: *std.Io.Reader, gc: *const GraphicsContext, pipeline_layout: vk.PipelineLayout) !void {
    const render_pass = global.dmabuf_render_pass;

    var pipelines: [256]vk.Pipeline = undefined;
    for (global.raster_descs[0..global.num_raster_descs], 0..) |raster_desc, i| {
        pipelines[i] = try createPipeline(gc, pipeline_layout, render_pass, raster_desc);
    }
    const num_pipelines = global.num_raster_descs;
    defer for (pipelines[0..num_pipelines]) |p| gc.dev.destroyPipeline(p, null);

    const pool = try gc.dev.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.dev.destroyCommandPool(pool, null);

    // Allocate one command buffer per dmabuf target
    var cmdbuf_array: [8]vk.CommandBuffer = undefined;
    const cmdbufs = cmdbuf_array[0..global.dmabuf_count];
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = global.dmabuf_count,
    }, cmdbufs.ptr);

    defer gc.dev.deviceWaitIdle() catch {};

    std.log.info("vow: ready for dmabuf draw commands", .{});

    var cmdbuf_started = false;
    var render_pass_active = false;
    var current_pipeline_index: u8 = 0;
    var current_buffer_index: u8 = 0;

    while (true) {
        const request: vowproto.Request = blk: {
            const val = reader.takeByte() catch |err| switch (err) {
                error.ReadFailed, error.EndOfStream => return,
                else => |e| return e,
            };
            break :blk std.enums.fromInt(vowproto.Request, val) orelse std.debug.panic(
                "invalid request in render loop {}",
                .{val},
            );
        };
        switch (request) {
            .begin_render_pass => {
                const buffer_index = try reader.takeByte();
                var clear_color: [4]f32 = undefined;
                try reader.readSliceAll(std.mem.asBytes(&clear_color));

                if (buffer_index >= global.dmabuf_count) {
                    std.log.err("begin_render_pass: buffer_index {} out of range", .{buffer_index});
                    return error.InvalidBufferId;
                }
                current_buffer_index = buffer_index;

                if (!cmdbuf_started) {
                    const cmdbuf = cmdbufs[current_buffer_index];
                    try gc.dev.resetCommandBuffer(cmdbuf, .{});
                    try gc.dev.beginCommandBuffer(cmdbuf, &.{});
                    cmdbuf_started = true;
                }

                const cmdbuf = cmdbufs[current_buffer_index];

                gc.dev.cmdBeginRenderPass(cmdbuf, &.{
                    .render_pass = render_pass,
                    .framebuffer = global.render_targets[current_buffer_index].framebuffer,
                    .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = global.dmabuf_extent },
                    .clear_value_count = 1,
                    .p_clear_values = @ptrCast(&vk.ClearValue{ .color = .{ .float_32 = clear_color } }),
                }, .@"inline");

                gc.dev.cmdBindPipeline(cmdbuf, .graphics, pipelines[current_pipeline_index]);

                const viewport: vk.Viewport = .{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(global.dmabuf_extent.width),
                    .height = @floatFromInt(global.dmabuf_extent.height),
                    .min_depth = 0,
                    .max_depth = 1,
                };
                gc.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
                gc.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&vk.Rect2D{
                    .offset = .{ .x = 0, .y = 0 },
                    .extent = global.dmabuf_extent,
                }));

                render_pass_active = true;
            },
            .draw => {
                if (!render_pass_active) {
                    std.log.err("draw without active render pass", .{});
                    return error.ProtocolError;
                }

                const vertex_count = try reader.takeInt(u32, native_endian);
                const memfd_id = try reader.takeInt(u32, native_endian);
                const vertex_offset = try reader.takeInt(u64, native_endian);
                const pixel_offset = try reader.takeInt(u64, native_endian);

                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("draw: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const base_addr = global.shared_mems[memfd_id].device_address orelse {
                    std.log.err("draw: memfd_id {} not imported (call gpu_malloc first)", .{memfd_id});
                    return error.NotImported;
                };

                const cmdbuf = cmdbufs[current_buffer_index];
                const push_data = [2]u64{ base_addr + vertex_offset, base_addr + pixel_offset };
                gc.dev.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf([2]u64), @ptrCast(&push_data));
                gc.dev.cmdDraw(cmdbuf, vertex_count, 1, 0, 0);
            },
            .end_render_pass => {
                if (!render_pass_active) {
                    std.log.err("end_render_pass without active render pass", .{});
                    return error.ProtocolError;
                }

                const cmdbuf = cmdbufs[current_buffer_index];
                gc.dev.cmdEndRenderPass(cmdbuf);
                render_pass_active = false;
            },
            .submit => {
                const buffer_index = try reader.takeByte();
                _ = buffer_index;
                if (!cmdbuf_started) {
                    std.log.err("submit without command buffer started", .{});
                    return error.ProtocolError;
                }
                if (render_pass_active) {
                    std.log.err("submit while render pass is active", .{});
                    return error.ProtocolError;
                }

                const target = &global.render_targets[current_buffer_index];
                const cmdbuf = cmdbufs[current_buffer_index];

                switch (target.transport) {
                    .shm => |shm| {
                        // Transition image from GENERAL to TRANSFER_SRC for copy to host buffer
                        gc.dev.cmdPipelineBarrier(cmdbuf, .{ .color_attachment_output_bit = true }, .{ .transfer_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&vk.ImageMemoryBarrier{
                            .src_access_mask = .{ .color_attachment_write_bit = true },
                            .dst_access_mask = .{ .transfer_read_bit = true },
                            .old_layout = .general,
                            .new_layout = .transfer_src_optimal,
                            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                            .image = target.image,
                            .subresource_range = .{
                                .aspect_mask = .{ .color_bit = true },
                                .base_mip_level = 0,
                                .level_count = 1,
                                .base_array_layer = 0,
                                .layer_count = 1,
                            },
                        }));

                        // Copy rendered image to host-backed buffer
                        gc.dev.cmdCopyImageToBuffer(cmdbuf, target.image, .transfer_src_optimal, shm.host_buffer, 1, @ptrCast(&vk.BufferImageCopy{
                            .buffer_offset = 0,
                            .buffer_row_length = 0,
                            .buffer_image_height = 0,
                            .image_subresource = .{
                                .aspect_mask = .{ .color_bit = true },
                                .mip_level = 0,
                                .base_array_layer = 0,
                                .layer_count = 1,
                            },
                            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                            .image_extent = .{ .width = target.width, .height = target.height, .depth = 1 },
                        }));
                    },
                    .dmabuf => {
                        // Zero copy — compositor reads directly from GPU memory
                    },
                }

                try gc.dev.endCommandBuffer(cmdbuf);
                cmdbuf_started = false;

                // Submit and wait for GPU completion
                try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
                    .command_buffer_count = 1,
                    .p_command_buffers = @ptrCast(&cmdbuf),
                }}, .null_handle);
                try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
            },
            .gpu_malloc => {
                const memfd_id = try reader.takeInt(u32, native_endian);
                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("gpu_malloc: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const sm = &global.shared_mems[memfd_id];
                if (sm.device_address != null) {
                    std.log.err("gpu_malloc: memfd_id {} already imported", .{memfd_id});
                    return error.AlreadyImported;
                }
                try importSharedMem(gc, sm, memfd_id);
            },
            .gpu_upload => {
                const memfd_id = try reader.takeInt(u32, native_endian);
                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("gpu_upload: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const sm = &global.shared_mems[memfd_id];
                if (sm.mapped == null or sm.gpu_mapped == null) {
                    std.log.err("gpu_upload: memfd_id {} not imported", .{memfd_id});
                    return error.NotImported;
                }
                @memcpy(sm.gpu_mapped.?[0..sm.size], sm.mapped.?[0..sm.size]);
            },
            .gpu_free => {
                const memfd_id = try reader.takeInt(u32, native_endian);
                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("gpu_free: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const sm = &global.shared_mems[memfd_id];
                if (sm.device_address == null) {
                    std.log.err("gpu_free: memfd_id {} not imported", .{memfd_id});
                    return error.NotImported;
                }
                try gc.dev.deviceWaitIdle();
                const fd = sm.fd;
                sm.deinit(gc);
                sm.* = .{ .fd = fd };
            },
            .bind_pipeline => {
                const pipeline_id = try reader.takeByte();
                if (!render_pass_active) {
                    std.log.err("bind_pipeline without active render pass", .{});
                    return error.ProtocolError;
                }
                if (pipeline_id >= num_pipelines) {
                    std.log.err("bind_pipeline: pipeline_id {} out of range (have {})", .{ pipeline_id, num_pipelines });
                    return error.InvalidPipelineId;
                }
                current_pipeline_index = pipeline_id;
                const cmdbuf = cmdbufs[current_buffer_index];
                gc.dev.cmdBindPipeline(cmdbuf, .graphics, pipelines[pipeline_id]);
            },
            else => std.debug.panic("unexpected request in dmabuf render loop: {}", .{@intFromEnum(request)}),
        }
    }
}

fn beginSwapchain(reader: *std.Io.Reader, gc: *const GraphicsContext, pipeline_layout: vk.PipelineLayout, map_on_present: u8) !void {
    // Query initial extent from the surface
    const caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
    std.log.info("vow: current_extent={}", .{caps.current_extent});
    var extent = caps.current_extent;
    if (extent.width == 0xFFFF_FFFF) {
        extent = .{ .width = 800, .height = 600 };
    }

    var swapchain = try Swapchain.init(gc, global.gpa, extent);
    defer swapchain.deinit();

    const render_pass = try createRenderPass(gc, swapchain);
    defer gc.dev.destroyRenderPass(render_pass, null);

    var pipelines: [256]vk.Pipeline = undefined;
    for (global.raster_descs[0..global.num_raster_descs], 0..) |raster_desc, i| {
        pipelines[i] = try createPipeline(gc, pipeline_layout, render_pass, raster_desc);
    }
    const num_pipelines = global.num_raster_descs;
    defer for (pipelines[0..num_pipelines]) |p| gc.dev.destroyPipeline(p, null);

    var framebuffers = try createFramebuffers(gc, global.gpa, render_pass, swapchain);
    defer destroyFramebuffers(gc, global.gpa, framebuffers);

    const pool = try gc.dev.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.dev.destroyCommandPool(pool, null);

    var cmdbufs = try allocateCommandBuffers(gc, pool, global.gpa, swapchain.swap_images.len);
    defer destroyCommandBuffers(gc, pool, global.gpa, cmdbufs);

    defer {
        swapchain.waitForAllFences() catch {};
        gc.dev.deviceWaitIdle() catch {};
    }

    std.log.info("vow: ready for draw commands", .{});

    var mapped = false;
    var cmdbuf_started = false;
    var render_pass_active = false;
    var current_pipeline_index: u8 = 0;

    // Render loop - driven by commands from parent
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
            .begin_render_pass => {
                var clear_color: [4]f32 = undefined;
                try reader.readSliceAll(std.mem.asBytes(&clear_color));

                if (!cmdbuf_started) {
                    const current_fence = swapchain.swap_images[swapchain.image_index].frame_fence;
                    _ = try gc.dev.waitForFences(1, @ptrCast(&current_fence), .true, std.math.maxInt(u64));

                    const cmdbuf = cmdbufs[swapchain.image_index];
                    try gc.dev.resetCommandBuffer(cmdbuf, .{});
                    try gc.dev.beginCommandBuffer(cmdbuf, &.{});
                    cmdbuf_started = true;
                }

                const cmdbuf = cmdbufs[swapchain.image_index];

                gc.dev.cmdBeginRenderPass(cmdbuf, &.{
                    .render_pass = render_pass,
                    .framebuffer = framebuffers[swapchain.image_index],
                    .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
                    .clear_value_count = 1,
                    .p_clear_values = @ptrCast(&vk.ClearValue{ .color = .{ .float_32 = clear_color } }),
                }, .@"inline");

                gc.dev.cmdBindPipeline(cmdbuf, .graphics, pipelines[current_pipeline_index]);

                const viewport: vk.Viewport = .{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(swapchain.extent.width),
                    .height = @floatFromInt(swapchain.extent.height),
                    .min_depth = 0,
                    .max_depth = 1,
                };
                gc.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
                gc.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&vk.Rect2D{
                    .offset = .{ .x = 0, .y = 0 },
                    .extent = swapchain.extent,
                }));

                render_pass_active = true;
            },
            .draw => {
                if (!render_pass_active) {
                    std.log.err("draw without active render pass", .{});
                    return error.ProtocolError;
                }

                const vertex_count = try reader.takeInt(u32, native_endian);
                const memfd_id = try reader.takeInt(u32, native_endian);
                const vertex_offset = try reader.takeInt(u64, native_endian);
                const pixel_offset = try reader.takeInt(u64, native_endian);

                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("draw: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const base_addr = global.shared_mems[memfd_id].device_address orelse {
                    std.log.err("draw: memfd_id {} not imported (call gpu_malloc first)", .{memfd_id});
                    return error.NotImported;
                };

                const cmdbuf = cmdbufs[swapchain.image_index];
                const push_data = [2]u64{ base_addr + vertex_offset, base_addr + pixel_offset };
                gc.dev.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf([2]u64), @ptrCast(&push_data));
                gc.dev.cmdDraw(cmdbuf, vertex_count, 1, 0, 0);
            },
            .end_render_pass => {
                if (!render_pass_active) {
                    std.log.err("end_render_pass without active render pass", .{});
                    return error.ProtocolError;
                }

                const cmdbuf = cmdbufs[swapchain.image_index];
                gc.dev.cmdEndRenderPass(cmdbuf);
                render_pass_active = false;
            },
            .present => {
                if (!cmdbuf_started) {
                    std.log.err("present without command buffer started", .{});
                    return error.ProtocolError;
                }
                if (render_pass_active) {
                    std.log.err("present while render pass is active", .{});
                    return error.ProtocolError;
                }

                const cmdbuf = cmdbufs[swapchain.image_index];
                try gc.dev.endCommandBuffer(cmdbuf);
                cmdbuf_started = false;

                const state = swapchain.present(cmdbuf) catch |err| switch (err) {
                    error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
                    else => |narrow| return narrow,
                };

                if (!mapped) {
                    if (map_on_present != 0) {
                        std.log.info("mapping window!", .{});
                        global.maybe_gc.?.wsi.mapWindow();
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
            .gpu_malloc => {
                const memfd_id = try reader.takeInt(u32, native_endian);
                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("gpu_malloc: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const sm = &global.shared_mems[memfd_id];
                if (sm.device_address != null) {
                    std.log.err("gpu_malloc: memfd_id {} already imported", .{memfd_id});
                    return error.AlreadyImported;
                }
                try importSharedMem(gc, sm, memfd_id);
            },
            .gpu_upload => {
                const memfd_id = try reader.takeInt(u32, native_endian);
                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("gpu_upload: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const sm = &global.shared_mems[memfd_id];
                if (sm.mapped == null or sm.gpu_mapped == null) {
                    std.log.err("gpu_upload: memfd_id {} not imported", .{memfd_id});
                    return error.NotImported;
                }
                @memcpy(sm.gpu_mapped.?[0..sm.size], sm.mapped.?[0..sm.size]);
            },
            .gpu_free => {
                const memfd_id = try reader.takeInt(u32, native_endian);
                if (memfd_id >= global.shared_mems.len) {
                    std.log.err("gpu_free: memfd_id {} out of range (have {})", .{ memfd_id, global.shared_mems.len });
                    return error.InvalidBufferId;
                }
                const sm = &global.shared_mems[memfd_id];
                if (sm.device_address == null) {
                    std.log.err("gpu_free: memfd_id {} not imported", .{memfd_id});
                    return error.NotImported;
                }
                try gc.dev.deviceWaitIdle();
                const fd = sm.fd;
                sm.deinit(gc);
                sm.* = .{ .fd = fd };
            },
            .bind_pipeline => {
                const pipeline_id = try reader.takeByte();
                if (!render_pass_active) {
                    std.log.err("bind_pipeline without active render pass", .{});
                    return error.ProtocolError;
                }
                if (pipeline_id >= num_pipelines) {
                    std.log.err("bind_pipeline: pipeline_id {} out of range (have {})", .{ pipeline_id, num_pipelines });
                    return error.InvalidPipelineId;
                }
                current_pipeline_index = pipeline_id;
                const cmdbuf = cmdbufs[swapchain.image_index];
                gc.dev.cmdBindPipeline(cmdbuf, .graphics, pipelines[pipeline_id]);
            },
            else => std.debug.panic("unexpected request in render loop: {}", .{@intFromEnum(request)}),
        }
    }
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

fn createPipeline(gc: *const GraphicsContext, layout: vk.PipelineLayout, render_pass: vk.RenderPass, raster_desc: vowproto.RasterDesc) !vk.Pipeline {
    const vert_shader = global.maybe_vert_shader orelse {
        std.log.err("no vertex shader", .{});
        return error.NoVertexShader;
    };
    const frag_shader = global.maybe_frag_shader orelse {
        std.log.err("no fragment shader", .{});
        return error.NoFragmentShader;
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
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &.{ .topology = raster_desc.topology.toVulkan(), .primitive_restart_enable = .false },
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
            .polygon_mode = raster_desc.polygon_mode.toVulkan(),
            .cull_mode = raster_desc.cull_mode.toVulkan(),
            .front_face = raster_desc.front_face.toVulkan(),
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = raster_desc.sample_count.toVulkan(),
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
                .blend_enable = if (raster_desc.blend_enable != 0) .true else .false,
                .src_color_blend_factor = raster_desc.src_color_blend_factor.toVulkan(),
                .dst_color_blend_factor = raster_desc.dst_color_blend_factor.toVulkan(),
                .color_blend_op = raster_desc.color_blend_op.toVulkan(),
                .src_alpha_blend_factor = raster_desc.src_alpha_blend_factor.toVulkan(),
                .dst_alpha_blend_factor = raster_desc.dst_alpha_blend_factor.toVulkan(),
                .alpha_blend_op = raster_desc.alpha_blend_op.toVulkan(),
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

/// Custom _start that preserves the dynamic linker's TLS setup.
///
/// vowexe always runs under a dynamic linker (it has PT_INTERP), so the
/// dynamic linker initializes TLS for all loaded libraries — including
/// whatever libc the DT_NEEDED marker was patched to. Zig's default _start
/// calls tls.initStatic() which overwrites the FS register with its own TLS
/// block, clobbering libc's thread-local storage and causing segfaults in
/// dlopen/dlerror. By providing our own _start we skip that step and let
/// the dynamic linker's TLS remain active, which works on both glibc and musl.
/// Exported so that `@hasDecl(root, "_start")` returns true in std.start,
/// preventing Zig from providing its own _start.
pub const _start = &vowStartEntry;

comptime {
    @export(&vowStartEntry, .{ .name = "_start" });
}

fn vowStartEntry() callconv(.naked) noreturn {
    // Prevent DWARF unwinders from unwinding past this frame.
    if (builtin.unwind_tables != .none or !builtin.strip_debug_info) asm volatile (switch (builtin.cpu.arch) {
            .x86_64 => ".cfi_undefined %%rip",
            .aarch64 => ".cfi_undefined lr",
            else => @compileError("unsupported arch"),
        });
    asm volatile (switch (builtin.cpu.arch) {
            .x86_64 =>
            \\ xorl %%ebp, %%ebp
            \\ movq %%rsp, %%rdi
            \\ andq $-16, %%rsp
            \\ callq %[func:P]
            ,
            .aarch64 =>
            \\ mov fp, #0
            \\ mov lr, #0
            \\ mov x0, sp
            \\ and sp, x0, #-16
            \\ b %[func]
            ,
            else => @compileError("unsupported arch"),
        }
        :
        : [func] "X" (&vowStartMain),
    );
}

fn vowStartMain(argc_argv_ptr: [*]usize) callconv(.c) noreturn {
    @setRuntimeSafety(false);
    @disableInstrumentation();

    const argc = argc_argv_ptr[0];
    const argv: [*][*:0]u8 = @ptrCast(argc_argv_ptr + 1);

    const envp_optional: [*:null]?[*:0]u8 = @ptrCast(@alignCast(argv + argc + 1));
    var envp_count: usize = 0;
    while (envp_optional[envp_count]) |_| : (envp_count += 1) {}
    const envp: [][*:0]u8 = @ptrCast(envp_optional[0..envp_count]);

    std.os.argv = argv[0..argc];
    std.os.environ = envp;

    // Set auxiliary vector so std library functions that need it still work.
    const auxv: [*]std.elf.Auxv = @ptrCast(@alignCast(envp.ptr + envp_count + 1));
    std.os.linux.elf_aux_maybe = auxv;

    // Zero out AT_BASE so std.process.getBaseAddress() returns the main
    // executable's base (via AT_PHDR) instead of the dynamic linker's base.
    // Without this, std.debug.dumpStackTrace() crashes because the non-libc
    // dl_iterate_phdr path uses getBaseAddress() to find ELF headers, and
    // AT_BASE points to ld-linux, not vowexe.
    {
        var i: usize = 0;
        while (auxv[i].a_type != std.elf.AT_NULL) : (i += 1) {
            if (auxv[i].a_type == std.elf.AT_BASE) {
                auxv[i].a_un.a_val = 0;
                break;
            }
        }
    }

    // NOTE: We intentionally do NOT call std.os.linux.tls.initStatic().
    // The dynamic linker already initialized TLS for our binary and libc.

    std.debug.maybeEnableSegfaultHandler();

    // Call main from a separate function that does NOT have
    // @setRuntimeSafety(false) / @disableInstrumentation(), so that
    // error return traces are properly tracked and @errorReturnTrace()
    // returns a valid trace.
    callMain();
}

fn callMain() noreturn {
    main() catch |e| {
        std.log.err("{s}", .{@errorName(e)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.posix.exit(0xff);
    };
    std.posix.exit(0);
}

const native_endian = builtin.cpu.arch.endian();

fn Cmsg(comptime T: type) type {
    const padding_size: usize = padLen(@sizeOf(c_ulong), @truncate(@sizeOf(T)));
    return extern struct {
        len: usize = @sizeOf(@This()) - padding_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [1]u8{0} ** padding_size,
    };
}
fn Pad(align_to: comptime_int) type {
    return switch (align_to) {
        4 => u2,
        8 => u3,
        else => @compileError("todo"),
    };
}
fn padLen(comptime align_to: comptime_int, len: Pad(align_to)) Pad(align_to) {
    return (0 -% len) & (align_to - 1);
}

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const vowproto = @import("vowproto");

const xcb = GraphicsContext.xcb;
const vk = @import("vulkan");
const vklazy = @import("vklazy.zig");

const GraphicsContext = @import("GraphicsContext.zig");
const Swapchain = @import("Swapchain.zig");
